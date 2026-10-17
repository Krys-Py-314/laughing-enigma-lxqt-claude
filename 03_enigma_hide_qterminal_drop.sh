#!/usr/bin/env bash
#
# hide_qterminal_drop.sh
#
# Removes the "QTerminal drop down" entry from the "System Tools" category
# of the LXQt panel's Fancy Menu on the minimal LXQt/Openbox desktop
# (Raspberry Pi 5, Raspberry Pi OS Lite 64-bit, Debian Trixie).
#
#     chmod +x hide_qterminal_drop.sh
#     ./hide_qterminal_drop.sh            # hide it for the current user
#     ./hide_qterminal_drop.sh --system   # hide it for every user (sudo)
#     ./hide_qterminal_drop.sh --undo     # show it again (add --system to
#                                         # undo a system-wide hide)
#
# How it works:
#     The entry comes from /usr/share/applications/qterminal-drop.desktop,
#     owned by the qterminal package. That file is NOT edited or deleted -
#     the next qterminal upgrade would simply put it back. Instead an
#     override with the same file name is written to a directory that the
#     XDG menu spec searches first, with NoDisplay=true added:
#
#         per user    : ~/.local/share/applications/qterminal-drop.desktop
#         system-wide : /usr/local/share/applications/qterminal-drop.desktop
#
#     NoDisplay=true only hides it from menus; "qterminal --drop" still works.
#     The normal "QTerminal" entry is not touched.
#
# Environment overrides:
#     ASSUME_YES=1      never prompt (non-interactive)
#

set -uo pipefail

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

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please do not run this script as root. Run as normal user with sudo privileges."
    exit 1
fi

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
ENTRY="qterminal-drop.desktop"
SRC="/usr/share/applications/${ENTRY}"
ASSUME_YES="${ASSUME_YES:-0}"
MODE="user"
UNDO=0

usage() {
    sed -n '9,13p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --system)  MODE="system" ;;
        --undo)    UNDO=1 ;;
        -h|--help) usage; exit 0 ;;
        *)         print_error "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

if [ "$MODE" = "system" ]; then
    DEST_DIR="/usr/local/share/applications"
    SUDO="sudo"
else
    DEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    SUDO=""
fi
DEST="${DEST_DIR}/${ENTRY}"

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

refresh_menu_cache() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        $SUDO update-desktop-database "$DEST_DIR" >/dev/null 2>&1 || true
    fi
    # Touching the directory wakes the panel's file watcher so the Fancy
    # Menu rebuilds itself without a restart.
    $SUDO touch "$DEST_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Undo
# ---------------------------------------------------------------------------
if [ "$UNDO" = "1" ]; then
    if [ ! -f "$DEST" ]; then
        print_status "No override at ${DEST} - nothing to undo."
        exit 0
    fi
    if ! grep -q '^X-Hidden-By=hide_qterminal_drop.sh$' "$DEST"; then
        print_error "${DEST} was not created by this script; leaving it alone."
        exit 1
    fi
    $SUDO rm -f -- "$DEST" || { print_error "Could not remove ${DEST}"; exit 1; }
    refresh_menu_cache
    print_status "Removed ${DEST}"
    print_status "\"QTerminal drop down\" will show in System Tools again."
    exit 0
fi

# ---------------------------------------------------------------------------
# Hide
# ---------------------------------------------------------------------------
print_status "Hiding \"QTerminal drop down\" from the Fancy Menu (${MODE})..."

if [ ! -f "$SRC" ]; then
    print_warning "${SRC} not found - is qterminal installed?"
    print_warning "Writing the override anyway so the entry stays hidden if it is installed later."
fi

if [ -f "$DEST" ] && ! grep -q '^X-Hidden-By=hide_qterminal_drop.sh$' "$DEST"; then
    if ! confirm "${DEST} already exists and was not made by this script. Replace it?"; then
        print_status "Left ${DEST} unchanged."
        exit 0
    fi
    BACKUP="${DEST}.bak.$(date +%Y%m%d-%H%M%S)"
    $SUDO cp -p -- "$DEST" "$BACKUP" && print_status "Backup: ${BACKUP}"
fi

TMP="$(mktemp)" || { print_error "mktemp failed"; exit 1; }
trap 'rm -f "$TMP"' EXIT

if [ -f "$SRC" ]; then
    # Copy the packaged entry (keeps Name/Exec/translations valid) and set
    # NoDisplay=true inside [Desktop Entry], dropping any existing NoDisplay
    # or Hidden line so the result is unambiguous.
    awk '
        /^\[/ {
            if (in_main && !done) { print "NoDisplay=true"; print "X-Hidden-By=hide_qterminal_drop.sh"; done = 1 }
            in_main = ($0 == "[Desktop Entry]")
        }
        in_main && /^(NoDisplay|Hidden|X-Hidden-By)[ \t]*=/ { next }
        { print }
        END { if (in_main && !done) { print "NoDisplay=true"; print "X-Hidden-By=hide_qterminal_drop.sh" } }
    ' "$SRC" >"$TMP"
else
    cat >"$TMP" <<'EOF'
[Desktop Entry]
Type=Application
Name=QTerminal drop down
Exec=qterminal --drop
Icon=utilities-terminal
Categories=Qt;System;TerminalEmulator;
NoDisplay=true
X-Hidden-By=hide_qterminal_drop.sh
EOF
fi

if ! grep -q '^NoDisplay=true$' "$TMP"; then
    print_error "Failed to build the override file."
    exit 1
fi

$SUDO mkdir -p -- "$DEST_DIR" || { print_error "Could not create ${DEST_DIR}"; exit 1; }
$SUDO install -m 0644 -- "$TMP" "$DEST" || { print_error "Could not write ${DEST}"; exit 1; }
refresh_menu_cache

if command -v desktop-file-validate >/dev/null 2>&1; then
    if ! desktop-file-validate "$DEST" >/dev/null 2>&1; then
        print_warning "desktop-file-validate reported issues with ${DEST} (the entry is still hidden)."
    fi
fi

print_status "Wrote ${DEST}"
print_status "\"QTerminal drop down\" is now hidden from System Tools."
print_status "If the menu still shows it, log out and back in (or reboot)."
print_status "To show it again: $0 --undo$([ "$MODE" = "system" ] && echo " --system")"

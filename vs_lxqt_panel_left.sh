#!/usr/bin/env bash
#
# vs_lxqt_panel_left.sh
#
# Sets the LXQt Fancy Menu option "Categories Position" to Left
# (Fancy Menu Settings > Categories Position) on Debian Trixie / Raspberry Pi 5.
#
#     chmod +x vs_lxqt_panel_left.sh
#     ./vs_lxqt_panel_left.sh            # categories on the left
#     ./vs_lxqt_panel_left.sh --right    # put them back on the right (default)
#
# How it works:
#     The settings dialog stores the choice in ~/.config/lxqt/panel.conf as
#     categoriesAtRight=<bool> inside every plugin section with
#     type=fancymenu (false = Left, true or missing = Right). This script
#     sets that key in each such section and leaves the rest of the file as
#     it is. A dated backup of panel.conf is kept next to it.
#
#     lxqt-panel writes panel.conf back when it exits, so a running panel is
#     stopped first, the file is edited, and the panel is started again.
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
    print_error "Please do not run this script as root. Run as your normal desktop user."
    exit 1
fi

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lxqt"
PANEL="${CONF_DIR}/panel.conf"
SYS_PANEL="/etc/xdg/lxqt/panel.conf"
ASSUME_YES="${ASSUME_YES:-0}"
VALUE="false"
SIDE="Left"

usage() {
    sed -n '8,10p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --right)   VALUE="true"; SIDE="Right" ;;
        --left)    VALUE="false"; SIDE="Left" ;;
        -h|--help) usage; exit 0 ;;
        *)         print_error "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

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

# Names of the panel.conf sections whose type is fancymenu.
fancymenu_sections() {
    awk '
        /^\[.*\][ \t]*$/ { sec = substr($0, 2, index($0, "]") - 2); next }
        sec != "" && /^[ \t]*type[ \t]*=[ \t]*fancymenu[ \t]*$/ { print sec }
    ' "$1"
}

print_status "Setting Fancy Menu \"Categories Position\" to ${SIDE}..."

# ---------------------------------------------------------------------------
# Find panel.conf
# ---------------------------------------------------------------------------
if [ ! -f /usr/share/lxqt/lxqt-panel/fancymenu.desktop ] && \
   ! ls /usr/lib/*/lxqt-panel/libfancymenu.so >/dev/null 2>&1; then
    print_warning "The Fancy Menu plugin was not found (it needs lxqt-panel 2.0+)."
    print_warning "The classic Application Menu (mainmenu) has no category position option."
fi

if [ ! -f "$PANEL" ]; then
    if [ -f "$SYS_PANEL" ]; then
        # The panel would do the same on its first save: start from the
        # system default and keep the user's copy from then on.
        mkdir -p -- "$CONF_DIR" || { print_error "Could not create ${CONF_DIR}"; exit 1; }
        cp -- "$SYS_PANEL" "$PANEL" || { print_error "Could not copy ${SYS_PANEL}"; exit 1; }
        print_status "No user panel.conf yet; started from ${SYS_PANEL}."
    else
        print_error "Neither ${PANEL} nor ${SYS_PANEL} exists."
        print_error "Start LXQt once (so the panel writes its config), then run this again."
        exit 1
    fi
fi

mapfile -t SECTIONS < <(fancymenu_sections "$PANEL")
if [ "${#SECTIONS[@]}" -eq 0 ]; then
    print_error "No Fancy Menu found in ${PANEL}."
    if grep -q '^[ \t]*type[ \t]*=[ \t]*mainmenu' "$PANEL"; then
        print_error "The panel uses the classic Application Menu (mainmenu), which has no"
        print_error "category position option. Add the \"Fancy Menu\" widget to the panel"
        print_error "(right-click the panel > Manage Widgets), then run this again."
    fi
    exit 1
fi
print_status "Fancy Menu section(s): ${SECTIONS[*]}"

# ---------------------------------------------------------------------------
# Stop the panel so it cannot overwrite the edit when it exits
# ---------------------------------------------------------------------------
PANEL_WAS_RUNNING=0
if pgrep -u "$(id -u)" -x lxqt-panel >/dev/null 2>&1; then
    PANEL_WAS_RUNNING=1
    print_status "Stopping lxqt-panel..."
    pkill -u "$(id -u)" -x lxqt-panel >/dev/null 2>&1
    for _ in $(seq 1 50); do
        pgrep -u "$(id -u)" -x lxqt-panel >/dev/null 2>&1 || break
        sleep 0.1
    done
    if pgrep -u "$(id -u)" -x lxqt-panel >/dev/null 2>&1; then
        print_error "lxqt-panel did not stop; nothing was changed."
        exit 1
    fi
    # The panel may have written a fresh copy on exit; re-read it.
    mapfile -t SECTIONS < <(fancymenu_sections "$PANEL")
fi

# ---------------------------------------------------------------------------
# Edit panel.conf
# ---------------------------------------------------------------------------
BACKUP="${PANEL}.bak.$(date +%Y%m%d-%H%M%S)"
cp -p -- "$PANEL" "$BACKUP" && print_status "Backup: ${BACKUP}"

TMP="$(mktemp "${PANEL}.XXXXXX")" || { print_error "mktemp failed"; exit 1; }
trap 'rm -f "$TMP"' EXIT

# In every fancymenu section: drop any existing categoriesAtRight line and
# write the new one directly under the section header.
awk -v secs="$(printf '%s\n' "${SECTIONS[@]}")" -v val="$VALUE" '
    BEGIN { n = split(secs, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
    /^\[.*\][ \t]*$/ {
        sec = substr($0, 2, index($0, "]") - 2)
        print
        if (sec in want) print "categoriesAtRight=" val
        next
    }
    (sec in want) && /^[ \t]*categoriesAtRight[ \t]*=/ { next }
    { print }
' "$PANEL" >"$TMP"

# Sanity check before replacing the real file.
BAD=0
for s in "${SECTIONS[@]}"; do
    got="$(awk -v s="$s" '
        /^\[.*\][ \t]*$/ { sec = substr($0, 2, index($0, "]") - 2); next }
        sec == s && /^categoriesAtRight=/ { sub(/^categoriesAtRight=/, ""); print }
    ' "$TMP")"
    [ "$got" = "$VALUE" ] || BAD=1
done
if [ "$BAD" = "1" ] || [ ! -s "$TMP" ]; then
    print_error "Editing panel.conf failed; the original is unchanged."
    exit 1
fi

chmod --reference="$PANEL" "$TMP" 2>/dev/null || chmod 0644 "$TMP"
mv -f -- "$TMP" "$PANEL" || { print_error "Could not write ${PANEL}"; exit 1; }
trap - EXIT
print_status "Set categoriesAtRight=${VALUE} in ${PANEL}"

# ---------------------------------------------------------------------------
# Start the panel again
# ---------------------------------------------------------------------------
if [ "$PANEL_WAS_RUNNING" = "1" ]; then
    # lxqt-session may restart the panel by itself; give it a moment.
    sleep 2
    if ! pgrep -u "$(id -u)" -x lxqt-panel >/dev/null 2>&1; then
        if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            print_status "Starting lxqt-panel..."
            ( setsid lxqt-panel >/dev/null 2>&1 & ) || true
        else
            print_warning "No display found to restart lxqt-panel from here."
            print_warning "Log out and back in to get the panel back."
        fi
    fi
    print_status "Done. Open the menu: categories are now on the ${SIDE}."
else
    print_status "Done. Categories will be on the ${SIDE} the next time LXQt starts."
fi

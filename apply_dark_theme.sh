APPLY DARK THEME


#!/bin/bash
# ==========================================
# apply_dark_theme.sh
# ==========================================
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

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please do not run this script as root. Run as normal user with sudo privileges."
    exit 1
fi

print_status "Starting Raspberry Dark Theme Installation..."

banner() {
    print_status " "
    print_status " $1"
    print_status " "
}

# ---------------------------------------------------------------------------
banner "01 Defining Globals / helpers  "
# ---------------------------------------------------------------------------

LOGFILE="$HOME/.qapply_dark_theme.log"
SKIPPED_PKGS=()
FAILED_STEPS=()

SKIP_SSH_SWAP="${SKIP_SSH_SWAP:-0}"
SKIP_PI_APPS="${SKIP_PI_APPS:-0}"
SKIP_TRIM="${SKIP_TRIM:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# ---------------------------------------------------------------------------
banner "02 Interface font size, applied to Qt/LXQt, GTK, Openbox and urxvt alike."
# ---------------------------------------------------------------------------

FONT_SIZE=12

# Desktop background colour requested: R:56 G:60 B:72
BG_COLOR="#383C48"
BG_DARKER="#2B2E38"
BG_LIGHTER="#4A4F60"
BORDER_COLOR="#22252E"
FG_COLOR="#E6E6E6"

# ---------------------------------------------------------------------------
note_fail() {
    FAILED_STEPS+=("$1")
    print_error "$1"
}

# True when apt has an installable candidate for the package.
# ---------------------------------------------------------------------------
pkg_available() {
    local cand
    cand="$(apt-cache policy -- "$1" 2>/dev/null | awk -F': ' '/Candidate:/{print $2; exit}')"
    [ -n "$cand" ] && [ "$cand" != "(none)" ]
}

# Install only packages that actually exist in the configured repositories.
# This is what keeps the run free of "Unable to locate package" failures.
# ---------------------------------------------------------------------------
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
# ---------------------------------------------------------------------------
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
# ---------------------------------------------------------------------------
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
# ---------------------------------------------------------------------------
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

: >"$LOGFILE"
print_status "Full command output is being logged to: $LOGFILE"

# ---------------------------------------------------------------------------

# Define theme names
LXQT_THEME="Arc-Dark"
OPENBOX_THEME="Arc-Dark"
ICON_THEME="Papirus-Dark"  # Common dark icon pair, change to "Arc" if preferred

# Ensure required configuration directories exist
mkdir -p "$HOME/.config/lxqt"
mkdir -p "$HOME/.config/openbox"
mkdir -p "$HOME/.config/gtk-3.0"
mkdir -p "$HOME/.config/gtk-4.0"

print_status "Applying dark themes across your system..."

apt_install arc-theme papirus-icon-theme lxqt-themes

# ==========================================
banner "03 Installing LXQt Panel & Widget Theme
# ==========================================
LXQT_CONF="$HOME/.config/lxqt/lxqt.conf"
touch "$LXQT_CONF"

# Set LXQt Theme
if grep -q "\[theme\]" "$LXQT_CONF"; then
    if grep -q "theme=" "$LXQT_CONF"; then
        sed -i '/^\[theme\]/,/^\[/ s/^theme=.*/theme='"$LXQT_THEME"'/' "$LXQT_CONF"
    else
        sed -i '/^\[theme\]/a theme='"$LXQT_THEME"'' "$LXQT_CONF"
    fi
else
    echo -e "\n[theme]\ntheme=$LXQT_THEME" >> "$LXQT_CONF"
fi

# Set Icon Theme in LXQt configuration
if grep -q "\[lxqt\]" "$LXQT_CONF"; then
    if grep -q "icon_theme=" "$LXQT_CONF"; then
        sed -i '/^\[lxqt\]/,/^\[/ s/^icon_theme=.*/icon_theme='"$ICON_THEME"'/' "$LXQT_CONF"
    else
        sed -i '/^\[lxqt\]/a icon_theme='"$ICON_THEME"'' "$LXQT_CONF"
    fi
else
    echo -e "\n[lxqt]\nicon_theme=$ICON_THEME" >> "$LXQT_CONF"
fi

# Force panel to respect the theme background
PANEL_CONF="$HOME/.config/lxqt/panel.conf"
if [ -f "$PANEL_CONF" ]; then
    if grep -q "background_color_theme=" "$PANEL_CONF"; then
        sed -i 's/^background_color_theme=.*/background_color_theme=true/' "$PANEL_CONF"
    fi
fi

# =============================================
banner "04 Configuring Openbox Window Borders "
# =============================================
RC_XML="$HOME/.config/openbox/rc.xml"

# If user doesn't have a local config, copy the default system template first
if [ ! -f "$RC_XML" ]; then
    if [ -f "/etc/xdg/openbox/rc.xml" ]; then
        cp /etc/xdg/openbox/rc.xml "$RC_XML"
    fi
fi

# Swap the <theme><name> tag inside the XML structure
if [ -f "$RC_XML" ]; then
    # Changes the first instance of <name> text found immediately after <theme>
    sed -i '/<theme>/,/<\/theme>/ s|<name>[^<]*</name>|<name>'"$OPENBOX_THEME"'</name>|' "$RC_XML"
fi

# ============================================================
banner "05 Configuring GTK 3 & GTK 4 Themes (For applications)
# ============================================================
GTK3_SETTINGS="$HOME/.config/gtk-3.0/settings.ini"
GTK4_SETTINGS="$HOME/.config/gtk-4.0/settings.ini"

GTK_CONTENT="[Settings]
gtk-theme-name=$LXQT_THEME
gtk-icon-theme-name=$ICON_THEME
gtk-application-prefer-dark-theme=1"

echo "$GTK_CONTENT" > "$GTK3_SETTINGS"
echo "$GTK_CONTENT" > "$GTK4_SETTINGS"

# ==========================================
banner "06 Refresh Session Components
# ==========================================
echo "Refreshing desktop environment components..."

# Reload Openbox styles live
if pgrep -x "openbox" > /dev/null; then
    openbox --reconfigure
fi

# Reload the LXQt panel
if pgrep -x "lxqt-panel" > /dev/null; then
    qdbus org.lxqt.panel /LXQtPanel org.lxqt.panel.main.reloadConfig >/dev/null 2>&1
fi

# Signal appearance change to running applications
if pgrep -x "lxqt-session" > /dev/null; then
    lxqt-config-appearance --refresh >/dev/null 2>&1 &
fi

banner "07 Done! Full dark setup successfully deployed."

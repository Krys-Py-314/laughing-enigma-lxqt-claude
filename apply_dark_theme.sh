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
banner "0. Starting installing base elements "
# ---------------------------------------------------------------------------

sudo apt install arc-theme papirus-icon-theme lxqt-themes

# Define theme names
LXQT_THEME="Arc-Dark"
OPENBOX_THEME="Arc-Dark"
ICON_THEME="Papirus-Dark"  # Common dark icon pair, change to "Arc" if preferred

# Ensure required configuration directories exist
mkdir -p "$HOME/.config/lxqt"
mkdir -p "$HOME/.config/openbox"
mkdir -p "$HOME/.config/gtk-3.0"
mkdir -p "$HOME/.config/gtk-4.0"

echo "Applying dark themes across your system..."

# ==========================================
banner "1. LXQt Panel and Widget Theme"
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

# ==========================================
# 2. Openbox Window Borders
# ==========================================
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

# ==========================================
# 3. GTK 3 & GTK 4 Themes (For applications)
# ==========================================
GTK3_SETTINGS="$HOME/.config/gtk-3.0/settings.ini"
GTK4_SETTINGS="$HOME/.config/gtk-4.0/settings.ini"

GTK_CONTENT="[Settings]
gtk-theme-name=$LXQT_THEME
gtk-icon-theme-name=$ICON_THEME
gtk-application-prefer-dark-theme=1"

echo "$GTK_CONTENT" > "$GTK3_SETTINGS"
echo "$GTK_CONTENT" > "$GTK4_SETTINGS"

# ==========================================
# 4. Refresh Session Components
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

echo "Done! Full dark setup successfully deployed."

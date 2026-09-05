#!/usr/bin/env bash
#
# inst_dark_theme_and_icons.sh
#
# Dark theme + icon pass for the minimal LXQt/Openbox desktop built by
# inst-min-lxqt-rpi5.sh. Run it AFTER that script.
#
#     chmod +x inst_dark_theme_and_icons.sh
#     ./inst_dark_theme_and_icons.sh
#
# Applies: Arc-Dark GTK2/GTK3, Papirus-Dark icons, a generated Arc-Dark-Square
# Openbox theme, Kvantum dark Qt styling, a 48px LXQt panel with a raspberry
# menu icon, and the PCManFM-Qt desktop with your icon/label settings.
#
# Environment overrides:
#     NO_DESKTOP=1     do not enable the PCManFM-Qt desktop process
#     NO_APPLETS=1     do not install the system tray applications
#     ASSUME_YES=1     never prompt (non-interactive)
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

print_status "Starting Dark Theme and Icons Setup..."

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
LOGFILE="$HOME/inst_dark_theme_and_icons.log"
SKIPPED_PKGS=()
FAILED_STEPS=()

NO_DESKTOP="${NO_DESKTOP:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# --- Arc-Dark's own palette, read from the theme's xfwm4 assets -------------
# Arc-Dark paints active and inactive titlebars the same (#2F343F) and
# distinguishes them by text colour alone. The requested "dark active, very
# dark inactive" needs a background difference, so the active bar uses
# Arc-Dark's main background and the inactive bar its headerbar colour - both
# authentic Arc-Dark values, so nothing clashes with the GTK theme.
ARC_ACTIVE_BG="#383C4A"     # Arc-Dark background      (dark)
ARC_INACTIVE_BG="#2F343F"   # Arc-Dark headerbar       (very dark)
ARC_ACTIVE_FG="#D3DAE3"     # Arc-Dark foreground
ARC_INACTIVE_FG="#808791"   # Arc-Dark xfwm4 inactive text
ARC_BORDER="#2B2E39"        # Arc-Dark border
ARC_SELECT="#5294E2"        # Arc blue
ARC_DISABLED="#6A7080"

# Desktop label colours requested: white text, R56 G60 B72 shadow.
DESKTOP_FG="#FFFFFF"
DESKTOP_SHADOW="#383C48"
DESKTOP_BG="#383C48"

UI_FONT_NAME="Ubuntu Nerd Font"
UI_FONT_SIZE=10
DESKTOP_LABEL_FONT="Sans"
DESKTOP_LABEL_SIZE=11

PANEL_HEIGHT=32
PANEL_ICON_SIZE=22

# The clock and the Caps/Num/Scroll indicator carry small text that gets hard
# to read on a 32px panel, so they are sized independently of the UI font.
PANEL_CLOCK_FONT_PT=12
PANEL_KB_FONT_PT=12

OB_THEME="Arc-Dark-Square"

banner() {
    print_status " "
    print_status " $1"
    print_status " "
}

note_fail() {
    FAILED_STEPS+=("$1")
    print_error "$1"
}

pkg_available() {
    local cand
    cand="$(apt-cache policy -- "$1" 2>/dev/null | awk -F': ' '/Candidate:/{print $2; exit}')"
    [ -n "$cand" ] && [ "$cand" != "(none)" ]
}

apt_install() {
    local want=("$@") ok=() miss=() p
    for p in "${want[@]}"; do
        if pkg_available "$p"; then ok+=("$p"); else miss+=("$p"); fi
    done
    if [ "${#miss[@]}" -gt 0 ]; then
        print_warning "Not offered by this release, skipping: ${miss[*]}"
        SKIPPED_PKGS+=("${miss[@]}")
    fi
    [ "${#ok[@]}" -eq 0 ] && return 0
    print_status "apt-get install: ${ok[*]}"
    if ! sudo apt-get install -y --no-install-recommends "${ok[@]}" >>"$LOGFILE" 2>&1; then
        note_fail "apt-get install failed for: ${ok[*]} (see $LOGFILE)"
        return 1
    fi
    return 0
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

# Set key=value inside [section] of an ini file, creating either as needed.
ini_set() {
    local file="$1" section="$2" key="$3" value="$4"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    if ! grep -q "^\[${section}\]" "$file"; then
        printf '\n[%s]\n' "$section" >>"$file"
    fi
    python3 - "$file" "$section" "$key" "$value" <<'PY'
import sys, io
path, section, key, value = sys.argv[1:5]
lines = io.open(path, encoding='utf-8').read().split('\n')
out, in_sec, done = [], False, False
for line in lines:
    st = line.strip()
    if st.startswith('[') and st.endswith(']'):
        if in_sec and not done:
            out.append('%s=%s' % (key, value)); done = True
        in_sec = (st == '[%s]' % section)
    elif in_sec and st.split('=')[0].strip() == key:
        if not done:
            out.append('%s=%s' % (key, value)); done = True
        continue
    out.append(line)
if in_sec and not done:
    out.append('%s=%s' % (key, value)); done = True
io.open(path, 'w', encoding='utf-8').write('\n'.join(out))
PY
}

: >"$LOGFILE"
print_status "Logging command output to: $LOGFILE"

# ===========================================================================
banner "01 - Pre-flight checks"
# ===========================================================================

if ! sudo -v; then
    print_error "This script needs sudo privileges."
    exit 1
fi
( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

if [ ! -f "$HOME/.config/openbox/rc.xml" ]; then
    print_warning "No ~/.config/openbox/rc.xml found."
    print_warning "This script is meant to run AFTER inst-min-lxqt-rpi5.sh."
    confirm "Continue anyway?" || exit 1
else
    print_status "Base desktop from inst-min-lxqt-rpi5.sh detected."
fi

# LXQt rewrites its own config files when the session exits. Editing them
# underneath a live session means logout silently reverts everything.
LXQT_RUNNING=no
if pgrep -x lxqt-session >/dev/null 2>&1; then
    LXQT_RUNNING=yes
    print_warning "An LXQt session is running right now."
    print_warning "LXQt rewrites lxqt.conf and panel.conf when it exits, which would"
    print_warning "revert these changes at logout. Best is to run this from a TTY"
    print_warning "(Ctrl+Alt+F2) with the desktop closed."
    confirm "Continue anyway? (the script will restart the panel at the end)" || exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    print_error "python3 is required for safe ini editing but was not found."
    exit 1
fi

sudo apt-get update >>"$LOGFILE" 2>&1 || print_warning "apt-get update reported problems."

# ===========================================================================
banner "02 - Installing themes, icons and Kvantum"
# ===========================================================================

apt_install arc-theme lxqt-themes papirus-icon-theme

# Kvantum packaging changed in Trixie: qt-style-kvantum is now one package
# serving both Qt5 and Qt6, the themes merged into qt-style-kvantum-themes,
# and qt5-/qt6-style-kvantum became transitional dummies. The versioned
# *-themes packages do not exist there at all - installing only those would
# bring the engine in via the dummies but leave no themes behind. Prefer the
# unified names, fall back to the split ones on Bookworm and earlier.
if pkg_available qt-style-kvantum; then
    apt_install qt-style-kvantum qt-style-kvantum-themes
else
    apt_install qt5-style-kvantum qt5-style-kvantum-themes
    apt_install qt6-style-kvantum qt6-style-kvantum-themes
fi

# lxqt-config provides the LXQt Configuration Center; pcmanfm-qt draws the
# desktop. Both may already be present from the base script.
apt_install lxqt-config pcmanfm-qt

if [ -d /usr/share/themes/Arc-Dark ]; then
    print_status "Arc-Dark GTK theme present."
else
    note_fail "Arc-Dark not found after install - GTK theming will not apply."
fi

if [ -d /usr/share/icons/Papirus-Dark ]; then
    print_status "Papirus-Dark icon theme present."
    ICON_THEME="Papirus-Dark"
else
    print_warning "Papirus-Dark missing; falling back to Numix-Circle."
    ICON_THEME="Numix-Circle"
fi

# ===========================================================================
banner "03 - Raspberry icon for the application menu"
# ===========================================================================

mkdir -p "$HOME/.local/share/icons"
RASPBERRY_ICON=""

# Prefer a real Raspberry Pi logo if the system has one.
for cand in \
    /usr/share/raspberrypi-artwork/raspberry-pi-logo.svg \
    /usr/share/raspberrypi-artwork/raspswirl.png \
    /usr/share/icons/PiXflat/apps/48/rpi.png \
    /usr/share/icons/Papirus-Dark/64x64/apps/raspberry-pi.svg \
    /usr/share/icons/Papirus/64x64/apps/raspberry-pi.svg ; do
    [ -f "$cand" ] && { RASPBERRY_ICON="$cand"; break; }
done

if [ -n "$RASPBERRY_ICON" ]; then
    print_status "Using system raspberry icon: $RASPBERRY_ICON"
else
    # Nothing suitable installed, so ship our own. A self-contained SVG is
    # more reliable than hunting for an icon name that varies between themes.
    RASPBERRY_ICON="$HOME/.local/share/icons/raspberry-menu.svg"
    cat >"$RASPBERRY_ICON" <<'SVGEOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
  <g fill="#75A928">
    <path d="M25 14c-5-4-11-4-13-1 -2 3 1 8 6 10 2-4 4-7 7-9z"/>
    <path d="M39 14c5-4 11-4 13-1 2 3-1 8-6 10 -2-4-4-7-7-9z"/>
    <path d="M32 10c-3 0-5 3-5 6 0 2 2 4 5 4s5-2 5-4c0-3-2-6-5-6z"/>
  </g>
  <g fill="#BC1142">
    <circle cx="24" cy="30" r="6"/>
    <circle cx="40" cy="30" r="6"/>
    <circle cx="32" cy="34" r="6.5"/>
    <circle cx="24" cy="41" r="6"/>
    <circle cx="40" cy="41" r="6"/>
    <circle cx="32" cy="48" r="6"/>
  </g>
  <g fill="#8E0B2E" opacity="0.45">
    <circle cx="32" cy="48" r="2.2"/>
    <circle cx="24" cy="41" r="2"/>
    <circle cx="40" cy="41" r="2"/>
  </g>
</svg>
SVGEOF
    print_status "Installed a bundled raspberry icon: $RASPBERRY_ICON"
fi

# ===========================================================================
banner "04 - Openbox: generating and applying the ${OB_THEME} theme"
# ===========================================================================

# arc-theme ships GTK2/3/4, metacity and xfwm4 assets but NO openbox-3 theme,
# so the window borders have to be built from Arc-Dark's own palette. Square
# 1px borders, flat fills, no rounding - matching the base desktop's look.
for base in "$HOME/.local/share/themes" "$HOME/.themes" "$HOME/.config/themes"; do
    mkdir -p "${base}/${OB_THEME}/openbox-3"
    cat >"${base}/${OB_THEME}/openbox-3/themerc" <<EOF
# ${OB_THEME} - Arc-Dark palette, square borders.
# Generated by inst_dark_theme_and_icons.sh
border.width: 1
padding.width: 4
padding.height: 3
window.handle.width: 0
window.client.padding.width: 0
window.client.padding.height: 0
menu.overlap: 0
menu.border.width: 1

*.border.color: ${ARC_BORDER}

# Active window: Arc-Dark background (dark)
window.active.title.bg: flat solid
window.active.title.bg.color: ${ARC_ACTIVE_BG}
window.active.title.separator.color: ${ARC_BORDER}
window.active.label.bg: parentrelative
window.active.label.text.color: ${ARC_ACTIVE_FG}
window.active.handle.bg: flat solid
window.active.handle.bg.color: ${ARC_ACTIVE_BG}
window.active.grip.bg: flat solid
window.active.grip.bg.color: ${ARC_ACTIVE_BG}
window.active.button.unpressed.bg: flat solid
window.active.button.unpressed.bg.color: ${ARC_ACTIVE_BG}
window.active.button.unpressed.image.color: ${ARC_ACTIVE_FG}
window.active.button.pressed.bg: flat solid
window.active.button.pressed.bg.color: ${ARC_SELECT}
window.active.button.pressed.image.color: #FFFFFF
window.active.button.hover.bg: flat solid
window.active.button.hover.bg.color: ${ARC_SELECT}
window.active.button.hover.image.color: #FFFFFF
window.active.button.disabled.bg: flat solid
window.active.button.disabled.bg.color: ${ARC_ACTIVE_BG}
window.active.button.disabled.image.color: ${ARC_DISABLED}

# Inactive window: Arc-Dark headerbar colour (very dark)
window.inactive.title.bg: flat solid
window.inactive.title.bg.color: ${ARC_INACTIVE_BG}
window.inactive.title.separator.color: ${ARC_BORDER}
window.inactive.label.bg: parentrelative
window.inactive.label.text.color: ${ARC_INACTIVE_FG}
window.inactive.handle.bg: flat solid
window.inactive.handle.bg.color: ${ARC_INACTIVE_BG}
window.inactive.grip.bg: flat solid
window.inactive.grip.bg.color: ${ARC_INACTIVE_BG}
window.inactive.button.unpressed.bg: flat solid
window.inactive.button.unpressed.bg.color: ${ARC_INACTIVE_BG}
window.inactive.button.unpressed.image.color: ${ARC_INACTIVE_FG}
window.inactive.button.pressed.bg: flat solid
window.inactive.button.pressed.bg.color: ${ARC_SELECT}
window.inactive.button.pressed.image.color: #FFFFFF
window.inactive.button.hover.bg: flat solid
window.inactive.button.hover.bg.color: ${ARC_SELECT}
window.inactive.button.hover.image.color: #FFFFFF
window.inactive.button.disabled.bg: flat solid
window.inactive.button.disabled.bg.color: ${ARC_INACTIVE_BG}
window.inactive.button.disabled.image.color: ${ARC_DISABLED}

menu.title.bg: flat solid
menu.title.bg.color: ${ARC_INACTIVE_BG}
menu.title.text.color: ${ARC_ACTIVE_FG}
menu.items.bg: flat solid
menu.items.bg.color: ${ARC_ACTIVE_BG}
menu.items.text.color: ${ARC_ACTIVE_FG}
menu.items.disabled.text.color: ${ARC_DISABLED}
menu.items.active.bg: flat solid
menu.items.active.bg.color: ${ARC_SELECT}
menu.items.active.text.color: #FFFFFF
menu.separator.color: ${ARC_BORDER}

osd.bg: flat solid
osd.bg.color: ${ARC_INACTIVE_BG}
osd.label.bg: parentrelative
osd.label.text.color: ${ARC_ACTIVE_FG}
osd.hilight.bg: flat solid
osd.hilight.bg.color: ${ARC_SELECT}
osd.unhilight.bg: flat solid
osd.unhilight.bg.color: ${ARC_ACTIVE_BG}
EOF
done
print_status "Openbox theme '${OB_THEME}' written (active ${ARC_ACTIVE_BG}, inactive ${ARC_INACTIVE_BG})."

# Point rc.xml at the new theme and font. The first <name> in rc.xml is the
# theme name; the rest belong to the <font> blocks.
RC="$HOME/.config/openbox/rc.xml"
if [ -f "$RC" ]; then
    cp -f "$RC" "${RC}.bak-$(date +%Y%m%d%H%M%S)"
    sed -i "0,/<name>[^<]*<\/name>/s//<name>${OB_THEME}<\/name>/" "$RC"
    print_status "rc.xml theme set to ${OB_THEME} (backup kept alongside it)."
    if command -v openbox >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
        openbox --reconfigure >>"$LOGFILE" 2>&1 || true
    fi
else
    print_warning "No ~/.config/openbox/rc.xml; skipping Openbox theme switch."
fi

# ===========================================================================
banner "05 - GTK 2 and GTK 3: Arc-Dark with dark mode"
# ===========================================================================

mkdir -p "$HOME/.config/gtk-3.0"
cat >"$HOME/.config/gtk-3.0/settings.ini" <<EOF
[Settings]
gtk-theme-name=Arc-Dark
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=${ICON_THEME}
gtk-font-name=${UI_FONT_NAME} ${UI_FONT_SIZE}
gtk-cursor-theme-name=Adwaita
gtk-enable-animations=0
gtk-menu-images=0
gtk-button-images=0
EOF

cat >"$HOME/.gtkrc-2.0" <<EOF
gtk-theme-name="Arc-Dark"
gtk-icon-theme-name="${ICON_THEME}"
gtk-font-name="${UI_FONT_NAME} ${UI_FONT_SIZE}"
gtk-menu-images=0
gtk-button-images=0
EOF
print_status "GTK2 and GTK3 set to Arc-Dark with ${ICON_THEME} icons."

# ===========================================================================
banner "06 - LXQt appearance: Kvantum dark, icons, font"
# ===========================================================================

LXQT_CONF="$HOME/.config/lxqt/lxqt.conf"
mkdir -p "$HOME/.config/lxqt"

# 'kvantum' is a real theme shipped by lxqt-themes, so the LXQt theme, the Qt
# widget style and the Kvantum engine all line up.
LXQT_THEME="kvantum"
[ -d /usr/share/lxqt/themes/kvantum ] || LXQT_THEME="dark"

ini_set "$LXQT_CONF" General __userfile__ true
ini_set "$LXQT_CONF" General icon_theme "${ICON_THEME}"
ini_set "$LXQT_CONF" General theme "${LXQT_THEME}"
ini_set "$LXQT_CONF" General single_click_activate false
ini_set "$LXQT_CONF" Qt font "\"${UI_FONT_NAME},${UI_FONT_SIZE},-1,5,50,0,0,0,0,0\""
ini_set "$LXQT_CONF" Qt style "kvantum-dark"
ini_set "$LXQT_CONF" Qt tool_button_style "ToolButtonTextBesideIcon"
print_status "LXQt: theme=${LXQT_THEME}, icons=${ICON_THEME}, style=kvantum-dark"
print_status "LXQt: font=${UI_FONT_NAME} ${UI_FONT_SIZE} (Normal)"

# LXQt reads the platform theme from session.conf's environment block.
SESSION_CONF="$HOME/.config/lxqt/session.conf"
ini_set "$SESSION_CONF" Environment QT_QPA_PLATFORMTHEME lxqt
ini_set "$SESSION_CONF" Environment QT_STYLE_OVERRIDE ""

# ===========================================================================
banner "07 - Kvantum: selecting a dark engine theme"
# ===========================================================================

KV_THEME=""
for cand in KvArcDark KvGnomeDark KvAdaptaDark KvYaruDark KvSimplicityDark KvDarkRed KvDark; do
    if [ -d "/usr/share/Kvantum/${cand}" ] || [ -d "$HOME/.config/Kvantum/${cand}" ]; then
        KV_THEME="$cand"; break
    fi
done

if [ -n "$KV_THEME" ]; then
    mkdir -p "$HOME/.config/Kvantum"
    ini_set "$HOME/.config/Kvantum/kvantum.kvconfig" General theme "$KV_THEME"
    print_status "Kvantum engine theme set to ${KV_THEME}."
else
    print_warning "No dark Kvantum theme found on this system."
    print_warning "The kvantum-dark Qt style still applies; pick an engine theme"
    print_warning "in Kvantum Manager (run: kvantummanager) if you want more control."
fi

if command -v kvantummanager >/dev/null 2>&1; then
    print_status "Kvantum Manager available as: kvantummanager"
else
    print_warning "kvantummanager not installed (qt5-style-kvantum / qt6-style-kvantum)."
fi

# ===========================================================================
banner "08 - PCManFM-Qt desktop: icons, labels and margins"
# ===========================================================================

PCM="$HOME/.config/pcmanfm-qt/lxqt/settings.conf"
mkdir -p "$(dirname "$PCM")"

ini_set "$PCM" Desktop Wallpaper ""
ini_set "$PCM" Desktop WallpaperMode "color"
ini_set "$PCM" Desktop BgColor "${DESKTOP_BG}"
ini_set "$PCM" Desktop FgColor "${DESKTOP_FG}"
ini_set "$PCM" Desktop ShadowColor "${DESKTOP_SHADOW}"
ini_set "$PCM" Desktop Font "\"${DESKTOP_LABEL_FONT},${DESKTOP_LABEL_SIZE},-1,5,50,0,0,0,0,0\""
ini_set "$PCM" Desktop DesktopIconSize 48
ini_set "$PCM" Desktop DesktopCellMargins "@Size(3 1)"
ini_set "$PCM" Desktop ShowHidden false
ini_set "$PCM" Behavior SingleClick false
print_status "Desktop: 48x48 icons, ${DESKTOP_LABEL_FONT} ${DESKTOP_LABEL_SIZE} labels,"
print_status "         white text on ${DESKTOP_SHADOW} shadow, 3px x 1px margins."

if [ "$NO_DESKTOP" = "1" ]; then
    print_warning "NO_DESKTOP=1 -> desktop process not enabled; settings written only."
else
    # inst-min-lxqt-rpi5.sh masked the desktop modules with Hidden=true stubs
    # to save memory. Enabling desktop icons means undoing that.
    for mod in lxqt-desktop pcmanfm-qt-desktop; do
        stub="$HOME/.config/autostart/${mod}.desktop"
        if [ -f "$stub" ] && grep -q '^Hidden=true' "$stub" 2>/dev/null; then
            rm -f "$stub"
            print_status "Removed the Hidden stub masking ${mod}."
        fi
    done

    cat >"$HOME/.config/autostart/pcmanfm-qt-desktop.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PCManFM-Qt Desktop
Comment=Draws desktop icons and the desktop background
Exec=pcmanfm-qt --desktop --profile=lxqt
Terminal=false
NoDisplay=true
X-LXQt-Module=false
EOF
    print_status "Desktop process enabled (costs roughly 30-45 MB RSS)."
    print_warning "This reverses the base script's zero-desktop-process choice."
    print_warning "Run with NO_DESKTOP=1 to keep the lighter xsetroot background."
fi

# ===========================================================================
banner "09 - LXQt panel: ${PANEL_HEIGHT}px tall, ${PANEL_ICON_SIZE}px icons, raspberry menu"
# ===========================================================================

PANEL="$HOME/.config/lxqt/panel.conf"
mkdir -p "$(dirname "$PANEL")"
[ -f "$PANEL" ] && cp -f "$PANEL" "${PANEL}.bak-$(date +%Y%m%d%H%M%S)"

# Resolve the quicklaunch targets that actually exist on this machine.
find_desktop() {
    local n
    for n in "$@"; do
        for d in /usr/share/applications "$HOME/.local/share/applications"; do
            [ -f "${d}/${n}.desktop" ] && { printf '%s' "${d}/${n}.desktop"; return 0; }
        done
    done
    return 1
}
QL_FM="$(find_desktop pcmanfm-qt org.lxqt.pcmanfm-qt)" || QL_FM=""
QL_TERM="$(find_desktop rxvt-unicode urxvt debian-uxterm)" || QL_TERM=""
QL_EDIT="$(find_desktop l3afpad leafpad)" || QL_EDIT=""

# urxvt ships no .desktop file on Debian, so provide one for quicklaunch.
if [ -z "$QL_TERM" ] && command -v urxvt >/dev/null 2>&1; then
    QL_TERM="$HOME/.local/share/applications/urxvt.desktop"
    cat >"$QL_TERM" <<'EOF'
[Desktop Entry]
Type=Application
Name=Terminal
Comment=rxvt-unicode terminal
Exec=urxvt
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
EOF
    print_status "Created a Terminal .desktop for urxvt (Debian ships none)."
fi

# lxqt-panel has no dedicated separator plugin; a small fixed spacer is the
# conventional stand-in, so each requested "Separator" becomes one.
cat >"$PANEL" <<EOF
[General]
__userfile__=true

[panel1]
alignment=-1
animation-duration=0
desktop=0
hidable=false
iconSize=${PANEL_ICON_SIZE}
lineCount=1
lockPanel=false
panelSize=${PANEL_HEIGHT}
plugins=mainmenu, showdesktop, desktopswitch, sep1, quicklaunch, sep2, taskbar, sep3, kbindicator, sep4, tray, statusnotifier, mount, volume, worldclock, quicklaunch2
position=Bottom
show-delay=0
visibleMargin=true
width=100
width-percent=true

[mainmenu]
type=mainmenu
icon=${RASPBERRY_ICON}
showText=false

[showdesktop]
type=showdesktop

[desktopswitch]
type=desktopswitch
labelType=0

[sep1]
type=spacer
size=8
expandable=false

[quicklaunch]
type=quicklaunch

[sep2]
type=spacer
size=8
expandable=false

[taskbar]
type=taskbar
buttonStyle=IconText
closeOnMiddleClick=true
iconByClass=false
showOnlyOneDesktopTasks=false

[sep3]
type=spacer
size=8
expandable=false

[kbindicator]
type=kbindicator
capsLockIsOn=true
numLockIsOn=true
scrollLockIsOn=true
font="${UI_FONT_NAME},${PANEL_KB_FONT_PT},-1,5,50,0,0,0,0,0"

[sep4]
type=spacer
size=8
expandable=false

[tray]
type=tray

[statusnotifier]
type=statusnotifier

[mount]
type=mount

[volume]
type=volume
showOnClicked=true

[worldclock]
type=worldclock
showWeekNumber=false
formatType=custom
useAdvancedManualFormat=true
customFormat=<span style="font-size:${PANEL_CLOCK_FONT_PT}pt;">hh:mm</span>

[quicklaunch2]
type=quicklaunch
EOF

# Fill the two quicklaunch plugins with whatever was actually found.
ql_index=0
for app in "$QL_FM" "$QL_TERM" "$QL_EDIT"; do
    [ -n "$app" ] || continue
    ql_index=$((ql_index + 1))
    ini_set "$PANEL" quicklaunch "apps\\${ql_index}\\desktop" "$app"
done
ini_set "$PANEL" quicklaunch "apps\\size" "$ql_index"
print_status "Quick Launch: ${ql_index} app(s) - ${QL_FM:-no FM} ${QL_TERM:-} ${QL_EDIT:-}"

# quicklaunch2 holds the leave/logout dialog.
LEAVE="$(find_desktop lxqt-leave)" || LEAVE=""
if [ -z "$LEAVE" ] && command -v lxqt-leave >/dev/null 2>&1; then
    LEAVE="$HOME/.local/share/applications/lxqt-leave.desktop"
    cat >"$LEAVE" <<'EOF'
[Desktop Entry]
Type=Application
Name=Leave
Comment=Log out, suspend, reboot or shut down
Exec=lxqt-leave
Icon=system-shutdown
Terminal=false
Categories=System;
EOF
fi
if [ -n "$LEAVE" ]; then
    ini_set "$PANEL" quicklaunch2 "apps\\1\\desktop" "$LEAVE"
    ini_set "$PANEL" quicklaunch2 "apps\\size" "1"
    print_status "Leave dialog added to the second Quick Launch."
else
    ini_set "$PANEL" quicklaunch2 "apps\\size" "0"
    print_warning "lxqt-leave not found; second Quick Launch left empty."
fi

print_status "Panel: ${PANEL_HEIGHT}px tall, ${PANEL_ICON_SIZE}px icons, bottom, raspberry menu icon."
print_warning "lxqt-panel has no true separator plugin; fixed 8px spacers are used."

# ===========================================================================
banner "10 - System tray applications (what statusnotifier actually shows)"
# ===========================================================================

# 'tray' and 'statusnotifier' are HOSTS, not containers: they display whatever
# applications register an icon with them. Nothing appears in either one
# because the applications are not installed or not autostarted - there is no
# panel setting that adds them.
#
# inst-min-lxqt-rpi5.sh deliberately left lxqt-powermanagement out and masked
# its autostart to save memory, so this step reverses that too.
print_warning "These applets cost roughly 50-70 MB RSS in total, which works"
print_warning "against the base script's minimum-memory goal. Skip this step"
print_warning "with NO_APPLETS=1 if you would rather keep the memory."

if [ "${NO_APPLETS:-0}" = "1" ]; then
    print_warning "NO_APPLETS=1 -> tray applications not installed."
else
    # lxqt-powermanagement : battery/power icon and idle actions
    # network-manager-gnome: nm-applet, the NetworkManager tray icon
    # qlipper              : clipboard history
    # lxqt-notificationd   : desktop notifications (usually already present)
    apt_install lxqt-powermanagement network-manager-gnome qlipper lxqt-notificationd

    # Undo the Hidden=true stubs the base script wrote to suppress these.
    for mod in lxqt-powermanagement lxqt-notificationd; do
        stub="$HOME/.config/autostart/${mod}.desktop"
        if [ -f "$stub" ] && grep -q '^Hidden=true' "$stub" 2>/dev/null; then
            rm -f "$stub"
            print_status "Unmasked autostart for ${mod}."
        fi
    done

    # Most of these ship their own /etc/xdg/autostart entry. Write a user one
    # only where the system file is absent, so nothing starts twice.
    add_autostart() {
        local name="$1" exec_cmd="$2" bin="${3:-}"
        [ -n "$bin" ] && ! command -v "$bin" >/dev/null 2>&1 && return 0
        if [ -f "/etc/xdg/autostart/${name}.desktop" ]; then
            print_status "${name}: autostarted by its own package."
            return 0
        fi
        cat >"$HOME/.config/autostart/${name}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${name}
Exec=${exec_cmd}
Terminal=false
NoDisplay=true
X-LXQt-Module=false
EOF
        print_status "${name}: user autostart entry written."
    }

    mkdir -p "$HOME/.config/autostart"
    add_autostart lxqt-powermanagement lxqt-powermanagement lxqt-powermanagement
    add_autostart nm-applet           "nm-applet"          nm-applet
    add_autostart qlipper             "qlipper"            qlipper
    add_autostart lxqt-notificationd  lxqt-notificationd   lxqt-notificationd

    print_status " "
    print_status "  These will appear in the tray after the next login:"
    for b in lxqt-powermanagement nm-applet qlipper lxqt-notificationd; do
        if command -v "$b" >/dev/null 2>&1; then
            printf '    present : %s\n' "$b"
        else
            printf '    MISSING : %s\n' "$b"
        fi
    done
    print_status " "
fi

# ===========================================================================
banner "11 - Applying"
# ===========================================================================

if [ "$LXQT_RUNNING" = "yes" ] && [ -n "${DISPLAY:-}" ]; then
    print_status "Restarting lxqt-panel to pick up the new layout..."
    pkill -x lxqt-panel >/dev/null 2>&1
    sleep 1
    ( setsid lxqt-panel >/dev/null 2>&1 & ) || true
    print_warning "A full log out and back in is still needed for the Qt style,"
    print_warning "GTK themes and the desktop process to apply everywhere."
else
    print_status "Log in to LXQt (or restart it) to see everything applied."
fi

# ===========================================================================
banner "12 - Summary"
# ===========================================================================

echo ""
echo "  Openbox theme  : ${OB_THEME}  (active ${ARC_ACTIVE_BG}, inactive ${ARC_INACTIVE_BG})"
echo "  GTK 2 / GTK 3  : Arc-Dark, prefer-dark enabled"
echo "  Icons          : ${ICON_THEME}"
echo "  LXQt theme     : ${LXQT_THEME}"
echo "  Qt style       : kvantum-dark${KV_THEME:+  (engine: ${KV_THEME})}"
echo "  Font           : ${UI_FONT_NAME} ${UI_FONT_SIZE}, Normal"
echo "  Panel          : ${PANEL_HEIGHT}px, ${PANEL_ICON_SIZE}px icons, bottom"
echo "  Menu icon      : ${RASPBERRY_ICON}"
if [ "$NO_DESKTOP" = "1" ]; then
echo "  Desktop        : not enabled (NO_DESKTOP=1); settings written"
else
echo "  Desktop        : PCManFM-Qt, 48x48 icons, ${DESKTOP_LABEL_FONT} ${DESKTOP_LABEL_SIZE} labels"
fi
echo ""

if [ "${#SKIPPED_PKGS[@]}" -gt 0 ]; then
    print_warning "Packages not offered by this release (skipped, not errors):"
    printf '           %s\n' "${SKIPPED_PKGS[@]}"
    echo ""
fi

if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
    print_error "${#FAILED_STEPS[@]} step(s) reported a problem:"
    printf '           %s\n' "${FAILED_STEPS[@]}"
    print_warning "Details are in $LOGFILE"
else
    print_status "All steps completed without errors."
fi

print_status " "
print_status "Fine-tune with:  lxqt-config    obconf-qt    kvantummanager"
print_status "Backups of rc.xml and panel.conf were kept alongside the originals."
print_status "Setup finished."

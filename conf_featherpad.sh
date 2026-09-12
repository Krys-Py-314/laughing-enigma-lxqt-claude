#!/usr/bin/env bash
#
# conf_featherpad.sh
#
# Configures FeatherPad for the minimal LXQt/Openbox desktop on a
# Raspberry Pi 5 (Raspberry Pi OS Lite 64-bit, Debian Trixie).
#
#     chmod +x conf_featherpad.sh
#     ./conf_featherpad.sh
#
# Settings applied (verified against FeatherPad's own config.cpp):
#     [text]   lineNumbers      = true
#     [text]   darkColorScheme  = true
#     [text]   darkBgColorValue = 40
#     [window] sysIcons         = true
#
# Environment overrides:
#     BG_VALUE=<0-50>   override the dark background value (default 40)
#     ASSUME_YES=1      never prompt (non-interactive)
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

print_status "Starting FeatherPad Configuration..."

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
# FeatherPad's config file is fp.conf, not fd.conf.
FP_CONF="$HOME/.config/featherpad/fp.conf"
BG_VALUE="${BG_VALUE:-40}"
ASSUME_YES="${ASSUME_YES:-0}"
FAILED_STEPS=()

banner() {
    print_status " "
    print_status " $1"
    print_status " "
}

note_fail() {
    FAILED_STEPS+=("$1")
    print_error "$1"
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

pkg_available() {
    local cand
    cand="$(apt-cache policy -- "$1" 2>/dev/null | awk -F': ' '/Candidate:/{print $2; exit}')"
    [ -n "$cand" ] && [ "$cand" != "(none)" ]
}

# Set key=value inside [section] of an ini file, creating either as needed.
# Existing keys are replaced in place so unrelated settings are preserved.
ini_set() {
    local file="$1" section="$2" key="$3" value="$4"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    python3 - "$file" "$section" "$key" "$value" <<'PY'
import sys, io
path, section, key, value = sys.argv[1:5]
lines = io.open(path, encoding='utf-8').read().split('\n')
out, in_sec, done, seen_sec = [], False, False, False
for line in lines:
    st = line.strip()
    if st.startswith('[') and st.endswith(']'):
        if in_sec and not done:
            out.append('%s=%s' % (key, value)); done = True
        in_sec = (st == '[%s]' % section)
        if in_sec:
            seen_sec = True
    elif in_sec and st.split('=')[0].strip() == key:
        if not done:
            out.append('%s=%s' % (key, value)); done = True
        continue
    out.append(line)
if in_sec and not done:
    out.append('%s=%s' % (key, value)); done = True
if not seen_sec:
    if out and out[-1].strip():
        out.append('')
    out.append('[%s]' % section)
    out.append('%s=%s' % (key, value))
io.open(path, 'w', encoding='utf-8').write('\n'.join(out))
PY
}

# Read back key=value from [section], for verification.
ini_get() {
    local file="$1" section="$2" key="$3"
    [ -f "$file" ] || return 1
    awk -F= -v sec="[$section]" -v k="$key" '
        $0 ~ /^\[/ { insec = ($0 == sec); next }
        insec && $1 == k { sub(/^[^=]*=/, ""); print; found=1; exit }
        END { exit !found }
    ' "$file"
}

# ===========================================================================
banner "01 - Pre-flight checks"
# ===========================================================================

if ! command -v python3 >/dev/null 2>&1; then
    print_error "python3 is required for safe ini editing but was not found."
    exit 1
fi

# The requested value only has meaning inside FeatherPad's own 0-50 range.
if ! [[ "$BG_VALUE" =~ ^[0-9]+$ ]] || [ "$BG_VALUE" -lt 0 ] || [ "$BG_VALUE" -gt 50 ]; then
    print_error "BG_VALUE must be an integer between 0 and 50 (got: ${BG_VALUE})."
    print_error "FeatherPad clamps darkBgColorValue to that range; 0 is blackest, 50 lightest."
    exit 1
fi

if command -v featherpad >/dev/null 2>&1; then
    print_status "FeatherPad is installed: $(featherpad --version 2>/dev/null | head -1)"
else
    print_warning "FeatherPad is not installed."
    if pkg_available featherpad; then
        if confirm "Install it now with apt?"; then
            if sudo apt-get install -y --no-install-recommends featherpad; then
                print_status "FeatherPad installed."
            else
                note_fail "Installing featherpad failed."
            fi
        else
            print_warning "Continuing anyway; the config will be ready when you install it."
        fi
    else
        print_warning "No 'featherpad' package candidate here; writing the config regardless."
    fi
fi

# FeatherPad writes its whole config on exit, so anything written underneath a
# running instance is discarded the moment that instance closes.
if pgrep -x featherpad >/dev/null 2>&1; then
    print_warning "FeatherPad is running right now."
    print_warning "It rewrites fp.conf when it exits, which would discard these changes."
    if confirm "Close FeatherPad now and continue?"; then
        pkill -x featherpad >/dev/null 2>&1
        sleep 2
        if pgrep -x featherpad >/dev/null 2>&1; then
            note_fail "FeatherPad is still running; close it manually and re-run."
            exit 1
        fi
        print_status "FeatherPad closed."
    else
        print_error "Close FeatherPad first, then re-run this script."
        exit 1
    fi
fi

# ===========================================================================
banner "02 - Backing up the existing configuration"
# ===========================================================================

mkdir -p "$(dirname "$FP_CONF")"
if [ -f "$FP_CONF" ]; then
    BACKUP="${FP_CONF}.bak-$(date +%Y%m%d%H%M%S)"
    cp -f "$FP_CONF" "$BACKUP"
    print_status "Existing config backed up to: $BACKUP"
else
    print_status "No existing fp.conf; a new one will be created."
    print_status "FeatherPad fills in its own defaults for everything not set here."
fi

# ===========================================================================
banner "03 - Applying the settings"
# ===========================================================================

# Two things here are load-bearing and were both verified by writing a config,
# running FeatherPad against it and reading back what FeatherPad itself wrote:
#
#   1. The section names are LOWERCASE - [text] and [window]. Capitalised
#      [Text]/[Window] sections are silently ignored: FeatherPad creates its
#      own lowercase sections and fills them with defaults, so the settings
#      appear to have been written yet nothing changes.
#   2. QSettings stores booleans as the literal words true/false, never yes/no.
ini_set "$FP_CONF" text   lineNumbers      true
print_status "[text]   lineNumbers      = true    (show line numbers)"

ini_set "$FP_CONF" text   darkColorScheme  true
print_status "[text]   darkColorScheme  = true    (dark mode)"

ini_set "$FP_CONF" text   darkBgColorValue "$BG_VALUE"
print_status "[text]   darkBgColorValue = ${BG_VALUE}      (dark background shade, 0-50)"

ini_set "$FP_CONF" window sysIcons         true
print_status "[window] sysIcons         = true    (use system icons where available)"

# ===========================================================================
banner "04 - Verifying what was written"
# ===========================================================================

check() {
    local section="$1" key="$2" expect="$3" got
    got="$(ini_get "$FP_CONF" "$section" "$key")" || got="<missing>"
    if [ "$got" = "$expect" ]; then
        printf '  %-18s %-16s = %-6s OK\n' "[$section]" "$key" "$got"
    else
        note_fail "[$section] $key is '${got}', expected '${expect}'"
    fi
}

check text   lineNumbers      true
check text   darkColorScheme  true
check text   darkBgColorValue "$BG_VALUE"
check window sysIcons         true

# ===========================================================================
banner "05 - Settings that FeatherPad does not expose"
# ===========================================================================

print_warning "Two requested settings have no key in fp.conf. Checked against"
print_warning "FeatherPad's own source (config.cpp and filedialog.h):"
echo ""
echo "  'default view = detailed list'"
echo "     FeatherPad hardcodes setViewMode(QFileDialog::Detail) in its file"
echo "     dialog. It is already detailed list view and there is nothing to"
echo "     set - but equally, nothing can change it."
echo ""
echo "  'show hidden files = yes'"
echo "     Remembered only in a static variable for the lifetime of the"
echo "     running process, never written to any config file. Toggle it inside"
echo "     an open/save dialog with Ctrl+H (or Alt+.); it holds until you quit"
echo "     FeatherPad, then resets."
echo ""
print_status "Both are file-dialog behaviours. If you meant the file manager,"
print_status "those are pcmanfm-qt settings (View > Detailed List, Ctrl+H) and"
print_status "live in ~/.config/pcmanfm-qt/lxqt/settings.conf instead."

# ===========================================================================
banner "06 - Summary"
# ===========================================================================

echo ""
echo "  Config file : $FP_CONF"
echo "  Line numbers: on"
echo "  Dark mode   : on, background value ${BG_VALUE}/50"
echo "  System icons: on"
echo ""

if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
    print_error "${#FAILED_STEPS[@]} problem(s):"
    printf '           %s\n' "${FAILED_STEPS[@]}"
else
    print_status "All four writable settings applied and verified."
fi

print_status " "
print_status "Start FeatherPad to see them:  featherpad"
print_status "Setup finished."

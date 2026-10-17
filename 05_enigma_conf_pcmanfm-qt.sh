#!/usr/bin/env bash
#
# k314-mini-conf_pcmanfm-qt.sh
#
# Configures FeatherPad for the minimal LXQt/Openbox desktop on a
# Raspberry Pi 5 (Raspberry Pi OS Lite 64-bit, Debian Trixie).
#
#     chmod +x k314-mini-conf_pcmanfm-qt.sh
#     ./k314-mini-conf_pcmanfm-qt.sh
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


# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
# FeatherPad's config file is fp.conf, not fd.conf.
FP_CONF="$HOME/.config/featherpad/fp.conf"
BG_VALUE="${BG_VALUE:-40}"
ASSUME_YES="${ASSUME_YES:-0}"
FAILED_STEPS=()

# ---------------------------------------------------------------------------
banner() {
    print_status " "
    print_status " $1"
    print_status " "
}
# ---------------------------------------------------------------------------
note_fail() {
    FAILED_STEPS+=("$1")
    print_error "$1"
}

printf ".\n.\n"
print_status "Configuration of [pcmanfm-qt] BEGIN..."
printf ".\n.\n"


if dpkg -s crudini &>/dev/null; then
  print_status "Crudini package found ..."
else
	printf "\n"
	print_warning "Crudini package not found... installing it..."
	sudo apt install -y --no-install-recommends crudini  
	print_status "Crudini installation done ..."
fi


for dir in "$HOME/.config/pcmanfm-qt/default" "$HOME/.config/pcmanfm-qt/lxqt"; do
	banner "Configuration of $dir"
    mkdir -p "$dir" && touch "$dir/settings.conf"
    crudini --set "$dir/settings.conf" "FolderView" "Mode" "detailed"
    crudini --set "$dir/settings.conf" "FolderView" "ShowHidden" "true"
    crudini --set "$dir/settings.conf" "FolderView" "SortHiddenLast" "false"
done

printf ".\n.\n"
print_status "Configuration of [pcmanfm-qt] END..."
printf ".\n.\n"


#!/usr/bin/env bash
#
# inst-lgpio-rpi5.sh
#
# Install the lgpio GPIO library (C library + Python 3 bindings) on a
# Raspberry Pi 5 running Debian 13 "Trixie" (arm64), starting from a bare
# system with nothing extra installed.
#
# Strategy:
#   1. Use the Debian packages (liblgpio1, liblgpio-dev, python3-lgpio)
#      when the configured apt sources provide them.
#   2. Otherwise build lg from upstream source (github.com/joan2937/lg)
#      into /usr/local, and install the Python binding with pip into
#      /usr/local/lib/python3.*/dist-packages.
#   3. Give the invoking user non-root access to /dev/gpiochip* via a
#      "gpio" group and a udev rule.
#
# Run as a NORMAL user with sudo rights:
#     chmod +x inst-lgpio-rpi5.sh
#     ./inst-lgpio-rpi5.sh
#
# Environment overrides:
#     FROM_SOURCE=1       skip the apt packages, always build from source
#     LG_REF=master       git branch/tag of joan2937/lg to build
#     SKIP_PYTHON=1       install only the C library
#

set -euo pipefail

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

trap 'print_error "Failed at line $LINENO: $BASH_COMMAND"' ERR

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please do not run this script as root. Run as normal user with sudo privileges."
    exit 1
fi

FROM_SOURCE="${FROM_SOURCE:-0}"
LG_REF="${LG_REF:-master}"
SKIP_PYTHON="${SKIP_PYTHON:-0}"
LG_URL="https://github.com/joan2937/lg/archive/refs/heads/${LG_REF}.tar.gz"
BUILD_DIR="$(mktemp -d -t lgpio-build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

export DEBIAN_FRONTEND=noninteractive

# Prompt for the sudo password once and keep the timestamp fresh.
sudo -v
while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null &

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
print_status "Starting lgpio installation..."

ARCH="$(dpkg --print-architecture)"
[ "$ARCH" = "arm64" ] || print_warning "Architecture is '$ARCH', expected arm64."

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${VERSION_CODENAME:-}" = "trixie" ] ||
        print_warning "OS codename is '${VERSION_CODENAME:-unknown}', expected trixie."
fi

MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
case "$MODEL" in
    *"Raspberry Pi 5"*) print_status "Detected: $MODEL" ;;
    *) print_warning "Board is '${MODEL:-unknown}', expected a Raspberry Pi 5." ;;
esac

# ---------------------------------------------------------------------------
# Base packages
# ---------------------------------------------------------------------------
print_status "Updating package lists..."
sudo apt-get update

print_status "Installing base tools..."
sudo apt-get install -y --no-install-recommends ca-certificates curl

# True when apt has an installable candidate for every package given.
apt_has() {
    local p cand
    for p in "$@"; do
        cand="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2}')"
        [ -n "$cand" ] && [ "$cand" != "(none)" ] || return 1
    done
}

# ---------------------------------------------------------------------------
# Option 1: Debian packages
# ---------------------------------------------------------------------------
install_from_apt() {
    local pkgs=(liblgpio1 liblgpio-dev)
    [ "$SKIP_PYTHON" = "1" ] || pkgs+=(python3 python3-lgpio)

    apt_has "${pkgs[@]}" || return 1

    print_status "Installing from apt: ${pkgs[*]}"
    sudo apt-get install -y --no-install-recommends "${pkgs[@]}"
}

# ---------------------------------------------------------------------------
# Option 2: build from upstream source
# ---------------------------------------------------------------------------
install_from_source() {
    local deps=(build-essential)
    [ "$SKIP_PYTHON" = "1" ] ||
        deps+=(python3 python3-dev python3-pip python3-setuptools python3-wheel swig)

    print_status "Installing build dependencies: ${deps[*]}"
    sudo apt-get install -y --no-install-recommends "${deps[@]}"

    print_status "Downloading lg ($LG_REF)..."
    curl -fsSL "$LG_URL" | tar -xz -C "$BUILD_DIR"
    local src
    src="$(find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"

    print_status "Building liblgpio..."
    make -C "$src" -j"$(nproc)"

    # A non-existent PYTHON skips the Makefile's own "setup.py install" step,
    # which PEP 668 / modern setuptools on Trixie no longer handle cleanly.
    print_status "Installing liblgpio into /usr/local..."
    sudo make -C "$src" install PYTHON=/nonexistent/python3
    sudo ldconfig

    if [ "$SKIP_PYTHON" != "1" ]; then
        print_status "Building and installing the Python lgpio module..."
        (
            cd "$src/PY_LGPIO"
            # As root, Debian's pip installs into /usr/local/lib/python3.*/
            # dist-packages, which stays out of the apt-managed tree.
            sudo env CFLAGS="-I$src -I/usr/local/include" LDFLAGS="-L/usr/local/lib" \
                python3 -m pip install --no-build-isolation \
                --break-system-packages --root-user-action=ignore .
        )
    fi
}

if [ "$FROM_SOURCE" != "1" ] && install_from_apt; then
    INSTALL_METHOD="apt"
else
    [ "$FROM_SOURCE" = "1" ] || print_warning "lgpio packages not available from apt; building from source."
    install_from_source
    INSTALL_METHOD="source"
fi

# ---------------------------------------------------------------------------
# GPIO permissions for the current user
# ---------------------------------------------------------------------------
print_status "Setting up 'gpio' group and udev rule for /dev/gpiochip*..."
getent group gpio >/dev/null || sudo groupadd --system gpio
sudo usermod -aG gpio "$USER"

sudo tee /etc/udev/rules.d/60-lgpio-gpiochip.rules >/dev/null <<'EOF'
# Allow members of the gpio group to use the GPIO character devices (lgpio).
SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=gpio --action=change || true

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
print_status "Verifying the C library..."
if [ -e /usr/include/lgpio.h ] || [ -e /usr/local/include/lgpio.h ]; then
    if ! dpkg -s gcc >/dev/null 2>&1; then
        sudo apt-get install -y --no-install-recommends gcc libc6-dev
    fi
    cat >"$BUILD_DIR/t.c" <<'EOF'
#include <stdio.h>
#include <lgpio.h>
int main(void) { printf("lgpio C library version 0x%08x\n", lguVersion()); return 0; }
EOF
    gcc -I/usr/local/include -L/usr/local/lib -o "$BUILD_DIR/t" "$BUILD_DIR/t.c" -llgpio
    "$BUILD_DIR/t"
else
    print_warning "lgpio.h not found; skipping C test."
fi

if [ "$SKIP_PYTHON" != "1" ]; then
    print_status "Verifying the Python module..."
    python3 -c 'import lgpio; print("Python lgpio loaded from", lgpio.__file__)'

    # Find the 40-pin header chip. On the Pi 5 it is the RP1 controller
    # (label "pinctrl-rp1"): gpiochip0 on current kernels, gpiochip4 on
    # older ones. Run with sudo because the new group is not active yet.
    print_status "GPIO chips seen by lgpio:"
    sudo python3 - <<'EOF' || print_warning "Could not enumerate GPIO chips."
import glob, lgpio
found = None
for dev in sorted(glob.glob("/dev/gpiochip*")):
    n = int(dev.removeprefix("/dev/gpiochip"))
    try:
        h = lgpio.gpiochip_open(n)
    except lgpio.error:
        continue
    _, lines, name, label = lgpio.gpio_get_chip_info(h)
    lgpio.gpiochip_close(h)
    print(f"  gpiochip{n}: {name} [{label}] {lines} lines")
    if label == "pinctrl-rp1" and found is None:
        found = n
if found is None:
    print("  WARNING: no pinctrl-rp1 chip found; the kernel may lack Pi 5 RP1 support.")
else:
    print(f"  => 40-pin header: lgpio.gpiochip_open({found})")
EOF
fi

print_status " "
print_status "lgpio installed (method: $INSTALL_METHOD)."
print_status "Log out and back in (or run 'newgrp gpio') so '$USER' can use GPIO without sudo."
print_status "Note: lgpio writes small .lgd-nfy* files in the working directory;"
print_status "      set LG_WD=/tmp (or another writable dir) if that is a problem."

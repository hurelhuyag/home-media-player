#!/bin/bash
# Home Media Player installer for an ODROID-HC4 running Armbian (Debian 13,
# mainline kernel). Turns a fresh Armbian install into the TV box:
#
#   curl -fsSL https://github.com/hurelhuyag/home-media-player/releases/latest/download/install.sh | sudo bash
#
# Options (after "bash -s --" when piping):
#   --version vX.Y.Z   install that release instead of the latest
#   --local DIR        install the .deb files from DIR instead of downloading
#   --no-surround      skip the 5.1 HDMI audio kernel modules
#   --reboot           reboot when done without asking
set -euo pipefail

REPO=hurelhuyag/home-media-player
VERSION=latest
LOCAL_DIR=
SURROUND=1
REBOOT=ask

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=$2; shift 2 ;;
        --local) LOCAL_DIR=$(cd "$2" && pwd); shift 2 ;;
        --no-surround) SURROUND=0; shift ;;
        --reboot) REBOOT=yes; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- checks -----------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ "$(dpkg --print-architecture)" = arm64 ] || die "this is for arm64 boards"
. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || warn "made for Debian 13 (trixie), this is ${PRETTY_NAME:-unknown}"
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)
HC4=0
case "$MODEL" in *ODROID-HC4*) HC4=1 ;; esac
[ "$HC4" = 1 ] || warn "board is '$MODEL'; HC4-specific settings and the 5.1 modules are skipped"
ARMBIAN_ENV=/boot/armbianEnv.txt
[ -f "$ARMBIAN_ENV" ] || warn "no $ARMBIAN_ENV, is this Armbian? kernel options are skipped"

NEED_REBOOT=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- kernel options ------------------------------------------------------------
# Adds or replaces KEY=VALUE in armbianEnv's extraargs
set_kernel_arg() {
    local arg=$1 key=${1%%=*} current new
    current=$(sed -n 's/^extraargs=//p' "$ARMBIAN_ENV")
    new=$(printf '%s\n' $current | grep -v "^${key}=" | tr '\n' ' ')
    new="${new}${arg}"
    [ "$new" = "$current" ] && return
    if grep -q '^extraargs=' "$ARMBIAN_ENV"; then
        sed -i "s|^extraargs=.*|extraargs=${new}|" "$ARMBIAN_ENV"
    else
        echo "extraargs=${new}" >> "$ARMBIAN_ENV"
    fi
    NEED_REBOOT=1
}

if [ "$HC4" = 1 ] && [ -f "$ARMBIAN_ENV" ]; then
    say "Kernel options"
    cp -n "$ARMBIAN_ENV" "$ARMBIAN_ENV.before-home-media-player"
    # 1080p: 4K@60 needs an HDMI 2.0 port and cable, and is too heavy for the GPU
    set_kernel_arg "video=HDMI-A-1:1920x1080@60"
    # The SATA controller drops off PCIe with link power management on
    set_kernel_arg "pcie_aspm=off"
    grep '^extraargs=' "$ARMBIAN_ENV"
fi

# ---- packages -----------------------------------------------------------------
say "Getting the packages"
if [ -n "$LOCAL_DIR" ]; then
    cp "$LOCAL_DIR"/*.deb "$WORK/"
else
    command -v curl >/dev/null || { apt-get update; apt-get install -y curl; }
    if [ "$VERSION" = latest ]; then
        API="https://api.github.com/repos/$REPO/releases/latest"
    else
        API="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
    fi
    URLS=$(curl -fsSL "$API" | grep -o '"browser_download_url": *"[^"]*\.deb"' | sed 's/.*"\(http[^"]*\)"/\1/')
    [ -n "$URLS" ] || die "no packages found in release $VERSION of $REPO"
    for url in $URLS; do
        echo "  $(basename "$url")"
        curl -fsSL -o "$WORK/$(basename "$url")" "$url"
    done
fi
ls "$WORK"/home-media-player_*.deb >/dev/null 2>&1 || die "home-media-player package missing"

say "Installing"
apt-get update
DEBS=("$WORK"/cec2uinput_*.deb "$WORK"/home-media-player_*.deb)

if [ "$SURROUND" = 1 ] && [ "$HC4" = 1 ] && ls "$WORK"/hmp-hdmi-multichannel-dkms_*.deb >/dev/null 2>&1; then
    # The modules are built against the running kernel, so its exact headers
    # are needed (the newest headers in the repo may be for a newer kernel).
    KPKG=$(dpkg-query -W -f '${Package} ${Version}\n' 'linux-image-*-meson64' 2>/dev/null | head -1)
    if [ -n "$KPKG" ]; then
        HEADERS="${KPKG%% *}"
        HEADERS="${HEADERS/linux-image-/linux-headers-}=${KPKG##* }"
        if apt-get install -y "$HEADERS"; then
            DEBS+=("$WORK"/hmp-hdmi-multichannel-dkms_*.deb)
            NEED_REBOOT=1
        else
            warn "couldn't install $HEADERS; 5.1 audio skipped (HDMI stays stereo)"
        fi
    else
        warn "no Armbian meson64 kernel package found; 5.1 audio skipped"
    fi
fi

DEBIAN_FRONTEND=noninteractive apt-get install -y "${DEBS[@]}"

# ---- done -----------------------------------------------------------------------
say "Done"
echo "The launcher starts on HDMI. Use the TV remote (HDMI-CEC) or a keyboard."
echo "Settings: /etc/default/home-media-player, /etc/default/cec2uinput,"
echo "          /etc/home-media-player/mpv/ (player keys and options)"

if [ "$NEED_REBOOT" = 1 ]; then
    if [ "$REBOOT" = yes ]; then
        reboot
    elif [ -r /dev/tty ] && { exec 3</dev/tty; } 2>/dev/null; then
        read -r -u 3 -p "A reboot is needed to finish (kernel options / audio modules). Reboot now? [Y/n] " answer || answer=n
        case "$answer" in [nN]*) echo "Reboot later with: sudo reboot" ;; *) reboot ;; esac
    else
        echo "Reboot to finish: sudo reboot"
    fi
fi

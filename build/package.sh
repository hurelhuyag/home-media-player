#!/bin/bash
# Assembles the .deb packages in dist/ from an already built kiosk bundle:
#   cec2uinput_<v>_arm64.deb, home-media-player_<v>_arm64.deb,
#   hmp-hdmi-multichannel-dkms_<v>_all.deb
#
#   CC=aarch64-linux-gnu-gcc build/package.sh      (cross, see build.sh)
#   build/package.sh                                (on an arm64 machine / CI)
#
# Environment: CC (C compiler for cec2uinput), VERSION (defaults to the
# kiosk's pubspec version), BUNDLE (Flutter release bundle).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUNDLE=${BUNDLE:-$ROOT/kiosk/build/linux/arm64/release/bundle}
VERSION=${VERSION:-$(sed -n 's/^version: *\([^+]*\).*/\1/p' "$ROOT/kiosk/pubspec.yaml")}
CC=${CC:-cc}
DIST="$ROOT/dist"
STAGE="$ROOT/build/stage"

[ -x "$BUNDLE/home_media_player" ] || { echo "no kiosk bundle in $BUNDLE, build it first" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$DIST" "$STAGE"
rm -f "$DIST"/*.deb

# Maintainer scripts: write stdin to $1 and make it executable
script() {
    cat > "$1"
    chmod 755 "$1"
}

# ---- cec2uinput -----------------------------------------------------------
echo "==> cec2uinput $VERSION"
PKG="$STAGE/cec2uinput"
make -C "$ROOT/cec2uinput" clean
make -C "$ROOT/cec2uinput" CC="$CC" CFLAGS="-O2 -g0" install DESTDIR="$PKG"
make -C "$ROOT/cec2uinput" clean
mkdir -p "$PKG/DEBIAN"
cat > "$PKG/DEBIAN/control" <<EOF
Package: cec2uinput
Version: $VERSION
Architecture: arm64
Maintainer: hurelhuyag <hurelhuyag@gmail.com>
Depends: libc6
Section: utils
Priority: optional
Homepage: https://github.com/hurelhuyag/home-media-player
Description: HDMI-CEC TV remote to virtual keyboard
 Registers the box on the HDMI-CEC bus under a custom name and turns the TV
 remote's key presses into Linux input events through uinput.
EOF
echo /etc/default/cec2uinput > "$PKG/DEBIAN/conffiles"
script "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    modprobe uinput 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable cec2uinput.service
    systemctl restart cec2uinput.service || true
fi
EOF
script "$PKG/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ]; then
    systemctl disable --now cec2uinput.service || true
fi
EOF
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DIST/cec2uinput_${VERSION}_arm64.deb"

# ---- kiosk ----------------------------------------------------------------
echo "==> home-media-player $VERSION"
PKG="$STAGE/home-media-player"
P="$ROOT/kiosk/packaging"
mkdir -p "$PKG/opt" "$PKG/DEBIAN"
cp -a "$BUNDLE" "$PKG/opt/home-media-player"
install -Dm755 "$P/session" "$PKG/usr/lib/home-media-player/session"
install -Dm644 "$P/home-media-player.service" "$PKG/lib/systemd/system/home-media-player.service"
install -Dm644 "$P/home-media-player.default" "$PKG/etc/default/home-media-player"
install -Dm644 "$P/pam" "$PKG/etc/pam.d/home-media-player"
install -Dm644 "$P/polkit.rules" "$PKG/etc/polkit-1/rules.d/50-home-media-player.rules"
# Transparent cursor theme for cage, see home-media-player.service
CURSORS="$PKG/usr/share/home-media-player/icons/default/cursors"
install -Dm644 "$P/cursor/empty" "$CURSORS/default"
for name in $(cat "$P/cursor/names"); do
    [ "$name" = default ] || ln -s default "$CURSORS/$name"
done
install -Dm644 "$P/cursor/index.theme" "$PKG/usr/share/home-media-player/icons/default/index.theme"
install -Dm644 "$P/mpv/mpv.conf" "$PKG/etc/home-media-player/mpv/mpv.conf"
install -Dm644 "$P/mpv/input.conf" "$PKG/etc/home-media-player/mpv/input.conf"
install -Dm644 "$P/mpv/scripts/README" "$PKG/etc/home-media-player/mpv/scripts/README"
cat > "$PKG/DEBIAN/control" <<EOF
Package: home-media-player
Version: $VERSION
Architecture: arm64
Maintainer: hurelhuyag <hurelhuyag@gmail.com>
Depends: cage, wlr-randr, chromium, libmpv2, libgtk-3-0t64, libepoxy0, mesa-libgallium, libegl1, libgles2, libpam-systemd, dbus, polkitd, udisks2, util-linux, fonts-noto-core, kbd, alsa-utils
Recommends: cec2uinput, hmp-hdmi-multichannel-dkms, fonts-noto-cjk
Section: video
Priority: optional
Installed-Size: $(du -sk "$PKG" | cut -f1)
Homepage: https://github.com/hurelhuyag/home-media-player
Description: TV kiosk: YouTube TV, local videos and photos
 Boots straight into a remote-controlled launcher on HDMI. YouTube TV runs in
 Chromium, local videos and music play through libmpv and photos in the app
 itself.
EOF
printf '%s\n' /etc/default/home-media-player \
    /etc/home-media-player/mpv/mpv.conf /etc/home-media-player/mpv/input.conf > "$PKG/DEBIAN/conffiles"
script "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    # A regular (non-system) user, so logind gives it a full seat session
    if ! id kiosk >/dev/null 2>&1; then
        useradd --create-home --user-group --shell /usr/sbin/nologin \
            --comment "Home Media Player kiosk" kiosk
    fi
    # input: read the cec2uinput device for the global HOME key
    for g in video render audio input; do
        getent group "$g" >/dev/null && usermod -aG "$g" kiosk
    done
    # Keep the kiosk's user manager running, so a restarted kiosk doesn't
    # wait for the previous session to wind down
    loginctl enable-linger kiosk 2>/dev/null || true
    systemctl daemon-reload
    systemctl set-default graphical.target
    systemctl enable home-media-player.service
    systemctl restart home-media-player.service || true
fi
EOF
script "$PKG/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ]; then
    systemctl disable --now home-media-player.service || true
fi
EOF
script "$PKG/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = purge ]; then
    loginctl disable-linger kiosk 2>/dev/null || true
    userdel -r kiosk 2>/dev/null || true
fi
EOF
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DIST/home-media-player_${VERSION}_arm64.deb"

# ---- 5.1 HDMI audio kernel modules (DKMS) ----------------------------------
SRC="$ROOT/kernel/hdmi-multichannel/src"
MOD_NAME=$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' "$SRC/dkms.conf")
MOD_VERSION=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$SRC/dkms.conf")
echo "==> $MOD_NAME-dkms $VERSION (module $MOD_VERSION)"
PKG="$STAGE/$MOD_NAME-dkms"
mkdir -p "$PKG/usr/src/$MOD_NAME-$MOD_VERSION" "$PKG/DEBIAN"
cp -a "$SRC/." "$PKG/usr/src/$MOD_NAME-$MOD_VERSION/"
cat > "$PKG/DEBIAN/control" <<EOF
Package: $MOD_NAME-dkms
Version: $VERSION
Architecture: all
Maintainer: hurelhuyag <hurelhuyag@gmail.com>
Depends: dkms
Recommends: linux-headers-current-meson64
Section: kernel
Priority: optional
Homepage: https://github.com/hurelhuyag/home-media-player
Description: 5.1/7.1 PCM over HDMI for Amlogic G12/SM1 (ODROID-HC4)
 Patched g12a-tohdmitx and meson-card-utils sound modules, built with DKMS,
 that let multichannel PCM reach the HDMI transmitter and let players see the
 HDMI channel map. Without them only stereo reaches the receiver. Needs the
 linux-headers package matching the running kernel; takes effect after a
 reboot.
EOF
script "$PKG/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ]; then
    dkms status -m $MOD_NAME -v $MOD_VERSION | grep -q . || dkms add -m $MOD_NAME -v $MOD_VERSION
    if ! dkms install -m $MOD_NAME -v $MOD_VERSION -k "\$(uname -r)"; then
        echo "$MOD_NAME: could not build for \$(uname -r); install the matching" >&2
        echo "linux-headers package and run: dkms autoinstall" >&2
    fi
    echo "$MOD_NAME: reboot to switch HDMI audio to multichannel."
fi
EOF
script "$PKG/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
dkms remove -m $MOD_NAME -v $MOD_VERSION --all >/dev/null 2>&1 || true
EOF
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DIST/${MOD_NAME}-dkms_${VERSION}_all.deb"

rm -rf "$STAGE"
ls -lh "$DIST"/*.deb

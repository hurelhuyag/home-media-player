#!/bin/bash
# Local build: compiles the kiosk on an arm64 machine over SSH and packages
# everything into dist/ (see package.sh). Releases are built by GitHub
# Actions instead (.github/workflows/release.yml).
#
#   BUILD_HOST=root@192.168.50.155 build/build.sh
#
# Flutter can't cross-compile Linux apps to arm64 (flutter/flutter#74929), so
# the kiosk is compiled on BUILD_HOST, an arm64 Debian 13 machine prepared with
# build/setup-build-host.sh (the HC4 itself works). cec2uinput is
# cross-compiled and the packages are assembled in the hmp-build Docker image.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=hmp-build:trixie
BUNDLE="$ROOT/kiosk/build/linux/arm64/release/bundle"

: "${BUILD_HOST:?set BUILD_HOST=user@arm64-host (see build/setup-build-host.sh)}"
REMOTE_DIR=/var/tmp/hmp-build
echo "==> building kiosk on $BUILD_HOST"
ssh "$BUILD_HOST" mkdir -p "$REMOTE_DIR/kiosk"
rsync -a --delete --exclude build/ --exclude .dart_tool/ --exclude .idea/ \
    "$ROOT/kiosk/" "$BUILD_HOST:$REMOTE_DIR/kiosk/"
ssh "$BUILD_HOST" "cd $REMOTE_DIR/kiosk && export PATH=/opt/flutter/bin:\$PATH &&
    flutter --suppress-analytics pub get && flutter --suppress-analytics build linux --release"
mkdir -p "$BUNDLE"
rsync -a --delete "$BUILD_HOST:$REMOTE_DIR/kiosk/build/linux/arm64/release/bundle/" "$BUNDLE/"

# The image takes a while to build; only (re)build it when missing or when
# asked to with REBUILD_IMAGE=1.
if [ -n "${REBUILD_IMAGE:-}" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -t "$IMAGE" "$ROOT/build"
fi
exec docker run --rm --user "$(id -u):$(id -g)" -e CC=aarch64-linux-gnu-gcc \
    -v "$ROOT:$ROOT" -w "$ROOT" "$IMAGE" "$ROOT/build/package.sh"

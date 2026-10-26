#!/bin/bash
# One-time setup of an arm64 Debian 13 machine (e.g. the HC4) as Flutter
# build host for build/build.sh:  ssh root@HOST bash -s < build/setup-build-host.sh
set -euo pipefail

FLUTTER_VERSION=${FLUTTER_VERSION:-3.47.1}

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates git curl unzip xz-utils rsync \
    build-essential clang cmake ninja-build pkg-config libstdc++-14-dev \
    libgtk-3-dev libmpv-dev libepoxy-dev liblzma-dev

if [ ! -x /opt/flutter/bin/flutter ]; then
    git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter
fi
export PATH=/opt/flutter/bin:$PATH
flutter --suppress-analytics config --no-analytics --enable-linux-desktop
flutter --suppress-analytics precache --linux
flutter --version

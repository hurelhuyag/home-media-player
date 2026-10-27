#!/bin/bash
# Builds Armbian's edge (7.3) meson64 kernel with the decoder and HDMI audio
# patches from LibreELEC, as Armbian .debs in <armbian-build>/output/debs.
#
#   kernel/hwdec-kernel/build.sh /path/to/armbian-build
#
# Needs Docker (or an Ubuntu/Debian host Armbian supports) and ~30 GB.
set -euo pipefail
ARMBIAN=${1:?usage: build.sh ARMBIAN_BUILD_DIR}
HERE=$(cd "$(dirname "$0")" && pwd)
[ -x "$ARMBIAN/compile.sh" ] || git clone --depth 1 https://github.com/armbian/build "$ARMBIAN"
# Copied, not linked: the build runs in a container that only sees its own tree
rsync -a --delete "$HERE/userpatches/" "$ARMBIAN/userpatches/"
cd "$ARMBIAN"
./compile.sh kernel BOARD=odroidhc4 BRANCH=edge KERNEL_CONFIGURE=no \
    ENABLE_EXTENSIONS=hmp-hwdec ${EXTRA_ARGS:-}
ls -l output/debs/linux-*edge-meson64*.deb

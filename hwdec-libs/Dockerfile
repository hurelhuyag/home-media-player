# Cross-builds hwdec-libs/build.sh for arm64 on an x86 machine:
#
#   docker build -t hmp-hwdec-libs hwdec-libs
#   docker run --rm -u $(id -u):$(id -g) -v $PWD:/src -w /src \
#       -e CROSS=aarch64-linux-gnu hmp-hwdec-libs hwdec-libs/build.sh
#
# On arm64 (the HC4, CI) install the same packages without ":arm64".
FROM debian:trixie

RUN dpkg --add-architecture arm64 \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl patch make gcc libc6-dev pkg-config meson ninja-build python3 dpkg-dev \
      gcc-aarch64-linux-gnu g++-aarch64-linux-gnu libc6-dev-arm64-cross \
      libdrm-dev:arm64 libudev-dev:arm64 libdav1d-dev:arm64 libgnutls28-dev:arm64 zlib1g-dev:arm64 \
      libass-dev:arm64 libplacebo-dev:arm64 libluajit-5.1-dev:arm64 libasound2-dev:arm64 \
      libegl-dev:arm64 libgbm-dev:arm64 libuchardet-dev:arm64 libjpeg-dev:arm64 \
      libarchive-dev:arm64 liblcms2-dev:arm64 libzimg-dev:arm64 libdisplay-info-dev:arm64 \
      libxml2-dev:arm64 \
 && rm -rf /var/lib/apt/lists/*

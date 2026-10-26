# Cross-compiles cec2uinput for the ODROID-HC4 (Armbian, Debian 13 trixie,
# arm64) against trixie's own glibc and kernel headers, and assembles the .debs.
FROM debian:trixie

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      make dpkg-dev gcc-aarch64-linux-gnu libc6-dev-arm64-cross linux-libc-dev-arm64-cross \
 && rm -rf /var/lib/apt/lists/*

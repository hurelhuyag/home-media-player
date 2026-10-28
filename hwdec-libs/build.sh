#!/bin/bash
# Builds the video libraries for hardware decoding on the ODROID-HC4:
#
#   - FFmpeg from LibreELEC's Amlogic branch (chewitt/ffmpeg), which has the
#     V4L2 request API hwaccels that Debian's FFmpeg lacks, patched to output
#     linear frames the GPU can show (ffmpeg-no-amlogic-fbc.patch)
#   - libmpv 0.41 with mpv's v4l2request hwdec (mpv PR #14690)
#
# They go to /usr/lib/home-media-player/hwdec (private, next to Debian's own
# FFmpeg and libmpv), staged in $DESTDIR. The kiosk picks them up when
# installed; see kiosk/packaging/session.
#
#   hwdec-libs/build.sh                          native, on arm64 Debian 13
#   CROSS=aarch64-linux-gnu hwdec-libs/build.sh  cross (hwdec-libs/Dockerfile)
#
# Build dependencies: see hwdec-libs/Dockerfile.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HERE/work}
DESTDIR=${DESTDIR:-$WORK/stage}
PREFIX=/usr/lib/home-media-player/hwdec
CROSS=${CROSS:-}
JOBS=${JOBS:-$(nproc)}

# Pinned to what LibreELEC ships for Amlogic (packages/multimedia/ffmpeg)
FFMPEG_COMMIT=c04518bc5d82315e57b14a7c915581a0667d1b4c
FFMPEG_SHA256=9f63165c2edd42073adb2c08d465cf550e58bdd42aa31cd3a84e75b8e3230676
MPV_VERSION=0.41.0
MPV_SHA256=ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209

fetch() { # url sha256 file
    if [ ! -f "$WORK/$3" ]; then
        curl -fsSL --retry 3 -o "$WORK/$3.part" "$1"
        mv "$WORK/$3.part" "$WORK/$3"
    fi
    echo "$2  $WORK/$3" | sha256sum -c --quiet
}

mkdir -p "$WORK"
fetch "https://github.com/chewitt/ffmpeg/archive/$FFMPEG_COMMIT.tar.gz" $FFMPEG_SHA256 ffmpeg.tar.gz
fetch "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz" $MPV_SHA256 mpv.tar.gz
# FFmpeg's HEVC hwaccel needs V4L2 controls newer than Debian 13's kernel
# headers (6.12): use Linux 7.3's, cleaned up like `make headers_install`
UAPI=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/include/uapi/linux
mkdir -p "$WORK/uapi/linux"
while read -r sum name; do
    fetch "$UAPI/$name?h=v7.3" "$sum" "uapi-$name"
    sed -E -e 's/([[:space:](])(__user|__force|__iomem)[[:space:]]/\1/g' \
        -e 's@^#include <linux/compiler.h>@@' "$WORK/uapi-$name" > "$WORK/uapi/linux/$name"
done <<'EOF'
800bac087b8aac0e00527d83a4bb9d96f485a4d0fad86bb36170ada7a2184b4f videodev2.h
8d97a2f9eb00414890308e26e2941174dfa8a7865fcfbb3ec472fb67081c372a v4l2-controls.h
d8f299f7aa92ad182d82ba721cc546e4a93421259bc1c19fbd676d4c6f6de47d v4l2-common.h
3b1b7b948496654bc75bacbb98fe270780ffd6a763303503afd10c0ef3289a6e media.h
EOF

# FFmpeg installs to its own root, for building mpv; the package gets its
# run-time files. REUSE_FFMPEG=1 keeps a finished FFmpeg build.
FFROOT=$WORK/ffmpeg-root
[ "${REUSE_FFMPEG:-0}" = 1 ] && [ -e "$FFROOT$PREFIX/lib/libavcodec.so" ] || REUSE_FFMPEG=0
[ "$REUSE_FFMPEG" = 1 ] || rm -rf "$WORK/ffmpeg" "$FFROOT"
rm -rf "$WORK/mpv" "$DESTDIR"
mkdir -p "$WORK/ffmpeg" "$WORK/mpv"
if [ "$REUSE_FFMPEG" = 0 ]; then
    tar -C "$WORK/ffmpeg" --strip-components=1 -xzf "$WORK/ffmpeg.tar.gz"
    patch -d "$WORK/ffmpeg" -p1 < "$HERE/ffmpeg-no-amlogic-fbc.patch"
fi
tar -C "$WORK/mpv" --strip-components=1 -xzf "$WORK/mpv.tar.gz"
patch -d "$WORK/mpv" -p1 < "$HERE/mpv-v4l2request.patch"

if [ -n "$CROSS" ]; then
    export PKG_CONFIG_LIBDIR=/usr/lib/$CROSS/pkgconfig:/usr/share/pkgconfig
    FFMPEG_CROSS=(--enable-cross-compile --arch=aarch64 --target-os=linux --cross-prefix=$CROSS- --pkg-config=pkg-config)
fi

# ---- FFmpeg -------------------------------------------------------------------
echo "==> FFmpeg ($FFMPEG_COMMIT)"
cd "$WORK/ffmpeg"
if [ "$REUSE_FFMPEG" = 0 ]; then
echo "amlogic-${FFMPEG_COMMIT:0:7}" > VERSION
./configure "${FFMPEG_CROSS[@]}" \
    --prefix=$PREFIX --libdir=$PREFIX/lib --shlibdir=$PREFIX/lib --incdir=$PREFIX/include \
    --extra-cflags="-I$WORK/uapi" --extra-ldflags="-Wl,-rpath,$PREFIX/lib" \
    --enable-shared --disable-static --disable-doc --disable-debug --enable-stripping \
    --enable-gpl --enable-version3 \
    --disable-programs --enable-ffmpeg --enable-ffprobe \
    --disable-devices --enable-network --enable-gnutls \
    --enable-libdrm --enable-libudev --enable-v4l2-request --enable-v4l2-m2m \
    --enable-libdav1d --enable-libxml2 \
    --disable-vaapi --disable-vdpau --disable-vulkan --disable-xlib --disable-libxcb --disable-sdl2
make -j"$JOBS"
grep -q 'define CONFIG_V4L2_REQUEST 1' config.h || { echo "FFmpeg built without v4l2-request" >&2; exit 1; }
make install DESTDIR="$FFROOT"
fi

# mpv builds against that FFmpeg: point its pkg-config files there
PC="$WORK/pkgconfig"
rm -rf "$PC"; mkdir -p "$PC"
for f in "$FFROOT$PREFIX"/lib/pkgconfig/*.pc; do
    sed "s|$PREFIX|$FFROOT$PREFIX|g" "$f" > "$PC/$(basename "$f")"
done

# ---- libmpv -------------------------------------------------------------------
echo "==> mpv $MPV_VERSION"
cd "$WORK/mpv"
MESON_CROSS=()
if [ -n "$CROSS" ]; then
    cat > "$WORK/cross.ini" <<EOF
[binaries]
c = '$CROSS-gcc'
cpp = '$CROSS-g++'
ar = '$CROSS-ar'
strip = '$CROSS-strip'
pkg-config = 'pkg-config'
[properties]
pkg_config_libdir = ['/usr/lib/$CROSS/pkgconfig', '/usr/share/pkgconfig']
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'cortex-a55'
endian = 'little'
EOF
    MESON_CROSS=(--cross-file "$WORK/cross.ini")
fi
meson setup build "${MESON_CROSS[@]}" \
    --prefix=$PREFIX --libdir=lib --buildtype=release --strip \
    -Dpkg_config_path="$PC" -Dc_link_args="-Wl,-rpath,$PREFIX/lib" \
    -Dlibmpv=true -Dcplayer=true -Dmanpage-build=disabled \
    -Dv4l2request=enabled -Ddrm=enabled -Dgbm=enabled -Degl=enabled -Degl-drm=enabled \
    -Dlua=luajit -Dalsa=enabled -Duchardet=enabled \
    -Dx11=disabled -Dwayland=disabled -Dvulkan=disabled -Dvaapi=disabled -Dvdpau=disabled \
    -Dpulse=disabled -Dpipewire=disabled -Dlibbluray=disabled
meson compile -C build -j "$JOBS"
DESTDIR="$DESTDIR" meson install -C build --no-rebuild --skip-subprojects

# Only what the player needs at run time (plus ffmpeg/ffprobe/mpv for tests)
cp -a "$FFROOT$PREFIX"/lib "$FFROOT$PREFIX"/bin "$DESTDIR$PREFIX"/
rm -rf "$DESTDIR$PREFIX"/{include,share} "$DESTDIR$PREFIX"/lib/pkgconfig

# Debian packages these link against, for the package's Depends
# (build/package.sh reads $DESTDIR.depends)
mkdir -p "$WORK/shlibs/debian"
echo "Source: hmp-hwdec-libs" > "$WORK/shlibs/debian/control"
[ -z "$CROSS" ] || export DEB_HOST_ARCH=arm64 DEB_HOST_MULTIARCH=$CROSS
(cd "$WORK/shlibs" && dpkg-shlibdeps -O --ignore-missing-info -l"$DESTDIR$PREFIX/lib" \
    $(find "$DESTDIR$PREFIX" -type f \( -name '*.so.*' -o -path '*/bin/*' \))) \
    | sed -n 's/^shlibs:Depends=//p' > "$DESTDIR.depends"
echo "Depends: $(cat "$DESTDIR.depends")"
ls -l "$DESTDIR$PREFIX"/lib "$DESTDIR$PREFIX"/bin

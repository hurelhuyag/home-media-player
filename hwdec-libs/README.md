# hwdec-libs: FFmpeg and libmpv for hardware decoding

Debian's FFmpeg has no V4L2 request API hwaccels, and the stateless Amlogic
decoder of the [hwdec kernel](../kernel/hwdec-kernel/README.md) only works
through them. `build.sh` builds, into the private prefix
`/usr/lib/home-media-player/hwdec` (next to Debian's own FFmpeg and libmpv):

| What | Version | Patches |
|---|---|---|
| FFmpeg | LibreELEC's Amlogic branch, [chewitt/ffmpeg](https://github.com/chewitt/ffmpeg) `c04518b` (what LibreELEC ships) | `ffmpeg-no-amlogic-fbc.patch` |
| libmpv (+ `mpv` for tests) | 0.41.0 | `mpv-v4l2request.patch`: mpv [PR #14690](https://github.com/mpv-player/mpv/pull/14690), the `v4l2request` hwdec |

FFmpeg also needs Linux 7.3's V4L2 headers (HEVC `EXT_SPS` controls that
Debian 13's 6.12 headers lack); the script fetches them from git.kernel.org,
checksummed. All downloads are pinned by SHA-256.

`build/package.sh` turns the result into `hmp-hwdec-libs`, with its Depends
from `dpkg-shlibdeps`. The player's session script puts the directory on
`LD_LIBRARY_PATH` when it's installed, and the player then defaults to
`hwdec=v4l2request` (`HMP_HWDEC` in `/etc/default/home-media-player`).
media_kit loads `libmpv.so.2` by name, so `LD_LIBRARY_PATH` is what switches
it; Chromium (YouTube) is started without it.

## Build

On x86, cross-compiled in Docker (a few minutes):

```sh
docker build -t hmp-hwdec-libs hwdec-libs
docker run --rm -u $(id -u):$(id -g) -v $PWD:/src -w /src \
    -e CROSS=aarch64-linux-gnu hmp-hwdec-libs hwdec-libs/build.sh
BUILD_HOST=root@HC4 build/build.sh     # packages it with the rest
```

Natively on arm64 Debian 13: install the packages in the `Dockerfile` without
`:arm64` and run `hwdec-libs/build.sh`. `WORK=dir` puts the downloads and
build tree elsewhere (then pass `HWDEC_STAGE=dir/stage` to `package.sh`);
`REUSE_FFMPEG=1` skips rebuilding FFmpeg.

## Testing on the box

```sh
B=/usr/lib/home-media-player/hwdec/bin
$B/ffmpeg -nostdin -v verbose -hwaccel v4l2request -i FILE -an -f null - 2>&1 | grep -E 'V4L2|CAPTURE'
#   Using V4L2 media driver meson-amvdec (7.3.0) for S264
#   Using CAPTURE buffer format NM12 (1920x1080)
$B/mpv --hwdec=v4l2request-copy --vo=null --frames=300 FILE   # "Using hardware decoding (v4l2request-copy)"
```

`--vo=gpu --gpu-context=drm` needs a connected display: with the TV off HDMI
reports disconnected and mpv finds "no usable DRM primary node".

## ffmpeg-no-amlogic-fbc.patch

For HEVC Main 10 (and VP9 profile 2) the driver lists `AM21C`, Amlogic's
compressed frame buffer format, as its only 10-bit capture format, and
FFmpeg prefers a format matching the stream's bit depth. Only the meson VPU
overlay can display AM21C (Kodi on LibreELEC does); in the player, which
renders through the GPU, 10-bit videos showed a blue picture. The patch skips
AM21C/AM21B when choosing, so FFmpeg falls back to `NV12M`, which the decoder
writes downsampled to 8 bits.

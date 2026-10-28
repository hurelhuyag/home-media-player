# Kernel with hardware video decoding (Armbian edge + LibreELEC patches)

Armbian's `edge` kernel for meson64 (Linux 7.3), built by the Armbian build
framework, with these patches from LibreELEC's Amlogic kernel
(`projects/Amlogic/patches/linux`, LibreELEC.tv `db99cd8`):

| LibreELEC | What |
|---|---|
| 0116–0128 | `amvdec`: stateless H.264/HEVC/VP9/MPEG-2 decoder (V4L2 request API), replaces the staging `meson-vdec` |
| 0129 | sound card exposes the HDMI channel map / ELD / IEC958 controls on its front-ends (5.1 PCM) |
| 0140–0143 | dw-hdmi: S/PDIF audio input (+ HBR), codec controls once per card |
| 0147–0153 | g12a-tohdmitx / axg-spdifout: 8 channels and non-PCM over S/PDIF→HDMI, clock fixes |
| 0155–0157 | G12/SM1 device trees: HDMI audio from the S/PDIF encoder (only the shared `.dtsi` and ODROID files) |

Left out: the GX-only (AIU) audio patches, the deinterlacer (0158–0162, needs
more clock patches) and everything for other SoCs (S4, …).

`userpatches/` is an Armbian userpatches tree:

- `kernel/archive/meson64-7.3/zz-libreelec-*.patch`: the patches above,
  re-exported against Armbian's tree (`zz-` sorts them after Armbian's own;
  `MAINTAINERS` and other boards' device trees dropped)
- empty `general-meson-vdec-*.patch` and `meson-*-vdec-*.patch` files: disable
  Armbian's patches to the staging driver that 0117 removes
- `extensions/hmp-hwdec.sh`: `VIDEO_MESON_AMVDEC=m`, no `VIDEO_MESON_VDEC`

The whole stack for hardware decoding:

| Part | Package | From |
|---|---|---|
| kernel with `meson-amvdec` | `linux-image-edge-meson64`, `linux-dtb-edge-meson64` | this directory |
| decoder microcode | `hmp-hwdec-firmware` | `build/package.sh` (LibreELEC/meson-firmware) |
| FFmpeg + libmpv with the V4L2 request API | `hmp-hwdec-libs` | [`hwdec-libs/`](../../hwdec-libs/README.md) |

With `hmp-hwdec-libs` installed the player uses `hwdec=v4l2request` by itself;
nothing to configure.

## Build

```sh
EXTRA_ARGS=KERNEL_GIT=shallow kernel/hwdec-kernel/build.sh ~/armbian-build   # clones Armbian there if missing
```

Needs Docker and ~30 GB; produces `linux-image-edge-meson64`,
`linux-dtb-edge-meson64` and `linux-headers-edge-meson64` in
`~/armbian-build/output/debs`. `KERNEL_GIT=shallow` because Armbian's full
kernel git bundle download kept failing (HTTP/2 `PROTOCOL_ERROR`). Built and
tested with Armbian build `cc07315` (2026-10-27), kernel 7.3.0.

## Install on the box

```sh
dpkg -i linux-image-edge-meson64_*.deb linux-dtb-edge-meson64_*.deb \
        hmp-hwdec-firmware_*.deb hmp-hwdec-libs_*.deb
apt-mark hold linux-image-edge-meson64 linux-dtb-edge-meson64
reboot
```

The edge packages install next to Armbian's `current` (6.18) ones; installing
them points `/boot/Image`, `/boot/dtb` and `/boot/uInitrd` at the new kernel.
Hold them: Armbian's apt repository has its own `linux-image-edge-meson64`
(without these patches) and replaces this one as soon as its version is
higher. An upgrade of `linux-image-current-meson64` also points the links back
at 6.18.

`hmp-hdmi-multichannel-dkms` isn't needed with this kernel (0129 and 0147 are
built in); its postinst says so and skips the build.

**Going back to 6.18**: point the links at the `current` files again, on the
box or, if it doesn't boot, on the SD card from another computer:

```sh
cd /boot
ln -sf vmlinuz-6.18.43-current-meson64 Image
ln -sf dtb-6.18.43-current-meson64 dtb
ln -sf uInitrd-6.18.43-current-meson64 uInitrd
```

## Results (ODROID-HC4, October 2026)

Tested over SSH with FFmpeg (`-hwaccel v4l2request`) and mpv from
`hmp-hwdec-libs`, then in the player on the TV:

| Test | Result |
|---|---|
| H.264 High 1080p | 83 fps decoding; a 10 s clip takes 1.75 s CPU (software: 26.8 s) |
| HEVC Main 1080p | 85–300 fps |
| HEVC Main 10, 720p / 1080p | 20 s of video in 1.4 s / 2.2 s, decoded to 8-bit NV12 (see below) |
| 30 starts of an H.264 file in a row | all fine (the staging driver and meson-sm1-codecs deadlocked here) |
| 15 seeks into H.264 and HEVC files | all fine (meson-sm1-codecs hard-hung the board) |
| end of file | clean, no kernel messages |
| in the player | H.264, HEVC and HEVC Main 10 files play with `v4l2request` (zero-copy, GL dmabuf) |

Not tested yet: VP9 and MPEG-2, 5.1 PCM and Dolby/DTS passthrough through the
new S/PDIF→HDMI audio path (0140–0157).

**HEVC Main 10**: for 10-bit streams the driver's only 10-bit capture format
is `AM21C`, Amlogic's compressed frame buffer format, which only the meson VPU
video overlay can display (that's how Kodi shows it). LibreELEC's FFmpeg picks
it, and in our player (GPU rendering) the picture was plain blue, while
`v4l2request-copy` failed with `Failed to transfer data to output frame: -22`.
The driver also writes linear `NV12M` for 10-bit streams, downsampled to
8 bits by the decoder; `hwdec-libs/ffmpeg-no-amlogic-fbc.patch` makes FFmpeg
take that. Nothing is lost on an 8-bit SDR TV.

**Widths whose rows aren't 64-byte aligned**: the decoder pads HEVC and VP9
rows to 32 bytes, Panfrost only imports frames with rows padded to 64
(`panfrost: rejecting image due to unsupported offset or stride alignment`
and a blue picture). 1280 and 1920 are fine; a 720x302 HEVC file wasn't. The
player switches such videos to `v4l2request-copy` (hardware decoding, frames
copied to memory), see `_checkHwdec` in `kiosk/lib/screens/player_screen.dart`.
H.264 rows are padded to 64 and not affected.

Known messages, harmless: `meson-drm: User-defined mode not supported:
"1920x1080i"` (the TV lists an interlaced mode) and `axg-tdm-iface: ASoC:
Failed to prepare bias: -5` at audio start.

## Updating the patches

```sh
kernel/hwdec-kernel/update-patches.sh LINUX_GIT_TREE ARMBIAN_BUILD LIBREELEC_TV [7.3]
```

applies Armbian's `meson64-7.3` set and then the LibreELEC files above to a
plain v7.3 tree (a git repo with the release committed once), one commit each
with `git am`, and exports them with `git format-patch` into `userpatches/`.
0142 needs less context (`-C1`, an include Armbian moved). Rerun it when
Armbian moves `edge` to a new kernel or LibreELEC updates its patches; the
output is reproducible, so `git diff` shows what changed.

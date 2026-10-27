# Hardware video decoding experiment (not used)

The player decodes in software (`HMP_HWDEC=no`). Notes from trying hardware
decoding on the ODROID-HC4 (Armbian, Linux 6.18.43, FFmpeg 7.1), October 2026.

## Stock decoder (`meson-vdec`, staging)

Hangs inside the kernel (`vdec_recycle` thread stuck in D state) when a stream
ends or is flushed: at the end of a file, on a playlist change, after seeking
past the end. The player freezes until a reboot. Reproduced at the stock CPU
speed and with `cma=512M`.

## meson-sm1-codecs

[github.com/ray38080289/meson-sm1-codecs](https://github.com/ray38080289/meson-sm1-codecs)
(commit `eb7a444`) replaces `meson-vdec` with a reworked out-of-tree module.

- Armbian's kernel has no `CONFIG_V4L2_H264`; the module needs
  `drivers/media/v4l2-core/v4l2-h264.c` built as an extra module
  (`KBUILD_EXTRA_SYMBOLS`).
- Its multi-instance HEVC firmware signals decoder mailbox 0, an interrupt
  mainline's device tree doesn't list (the driver warns "HEVC mailbox IRQ is
  unavailable" and HEVC decodes nothing). `sm1-vdec-mailbox-irqs.dts` adds it,
  matching unifreq's linux-6.18.y `meson-g12-common.dtsi`:
  `armbian-add-overlay sm1-vdec-mailbox-irqs.dts`.

With the overlay, from the start of a file:

| Stream | Result |
|---|---|
| H.264 1080p30 | 128 fps, but 8 of 10 runs deadlocked at start-up (source-change handshake) |
| HEVC 8-bit 1080p | 270 fps |
| HEVC 10-bit 720p / 1080p | 529 / 404 fps (software: ~27 fps for 1080p) |

Seeking into HEVC files (`ffmpeg -ss`) failed every time: no frames, FFmpeg
aborts, and after a few runs the whole board hard-hung (no network, power cut
needed). Not usable for a player yet; worth retrying when the driver matures.

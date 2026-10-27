# HDMI passthrough experiment (not working, not installed)

> **Multichannel PCM was solved separately** by two small module patches, see
> `../hdmi-multichannel/`. What follows is about Dolby/DTS bitstream
> passthrough, which still doesn't work.
>
> **Next step:** the LibreELEC S/PDIF→HDMI patches named below are now built
> into the [hwdec kernel](../hwdec-kernel/README.md) (Linux 7.3); passthrough
> with it hasn't been tested yet.

Research notes from trying to get 5.1 (Dolby Digital / DD+ / DTS) out of the
ODROID-HC4 over HDMI with the mainline kernel (Armbian 6.18). Kept so the next
attempt doesn't start from zero.

## Findings

- **Multichannel PCM** (solved, see `../hdmi-multichannel/`): the
  g12a-tohdmitx glue got an invented two-slot TDM mask, so 6/8 channel
  streams were set up as stereo on the HDMI side.
- **Passthrough:** mainline `dw-hdmi` never marks I2S audio as non-PCM:
  `dw_hdmi_set_channel_status()` only writes the sample-rate/word-length bytes.
  A receiver (Sony STR-DH590) shows "Linear PCM" and plays the bitstream as a
  buzz.
- On this DesignWare HDMI TX (v2.01a, Amlogic SM1):
  - `FC_AUDSCHNLS0` (0x1067) keeps only bit 0; there's no non-audio bit to set.
  - `AUD_CONF2` (0x3103): bit 1 (`NLPCM`) is writable, but with it set the
    receiver gets no audio at all; bit 2 (`insert_pcuv`) isn't implemented.
- Amlogic's vendor kernel does passthrough by feeding the HDMI TX from its
  S/PDIF block (the "TOHDMITX SPDIF SRC" mux), which carries the channel status
  in the stream. Mainline has neither an S/PDIF output link in the HC4 device
  tree nor S/PDIF input support in the HDMI driver. LibreELEC's Amlogic kernel
  (Linux 7.3) has patches for exactly this: 0141-0143 (dw-hdmi S/PDIF input),
  0149-0151 (axg-spdifout non-PCM, eight channels), 0153 (audio clocks),
  0155-0157 (G12/SM1 device tree). Some touch built-in code and the device
  tree, so it needs a full custom kernel.
- Don't read `/sys/kernel/debug/regmap/ff600000.hdmi-tx/registers`: reading the
  whole range hangs the board.

## What's here

`src/` is the stable v6.18.43 `dw-hdmi-i2s-audio` module with runtime
parameters for the experiments (`nonaudio_conf2`, `pcm_conf2`,
`nonaudio_schnls0`, `debug`), buildable with DKMS against matching
`linux-headers-current-meson64`. mpv needs an ALSA device that accepts the
`AES0..3` arguments of `--audio-spdif` and writes them to the HDMI codec's
"IEC958 Playback Default" control; the plain `hw` device rejects them and mpv
silently decodes instead.

`build/make-surround-test.sh` makes channel-ID test files in AC-3, E-AC-3, DTS
and 6-channel FLAC.

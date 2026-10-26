# hmp-hdmi-multichannel

DKMS package with two patched Amlogic sound modules that make **multichannel
PCM (5.1/7.1) over HDMI** work on the ODROID-HC4 (SM1) with Armbian's mainline
6.18 kernel. Without them only the front left/right pair reaches the receiver.

| Module | Patch | Fix |
|---|---|---|
| `snd-soc-meson-g12a-tohdmitx` | `0147` | The HDMI TX glue no longer gets an invented two-slot TDM mask, which described every 6/8 channel stream to the HDMI transmitter as stereo. |
| `snd-soc-meson-card-utils` | `0129` | The HDMI codec's ELD, channel map and IEC958 controls are mirrored onto the front-end PCM devices, so players (mpv) find the HDMI channel order (FL FR LFE FC RL RR) and reorder audio for it. |

Both patches are from LibreELEC's Amlogic kernel patch set
(`projects/Amlogic/patches/linux/` in LibreELEC.tv), applied to the v6.18.43
sources. The packaged `.c` files are already patched; `patches/` has the
originals for reference.

Installed into `/lib/modules/<kernel>/updates/dkms`, which takes precedence
over the kernel's own modules. DKMS rebuilds them for new 6.18.x kernels
(needs the matching `linux-headers-current-meson64`) and skips other series.

Dolby/DTS bitstream passthrough needs more of LibreELEC's patches (HDMI audio
from the S/PDIF encoder, device tree changes, built-in dw-hdmi changes), so a
full custom kernel; see `../passthrough-research/`.

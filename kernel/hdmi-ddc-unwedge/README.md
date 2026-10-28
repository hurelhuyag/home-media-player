# HDMI DDC unwedge overlay

Device tree overlay for the ODROID-HC4 that lets the HDMI driver recover its
DDC bus (the I2C link that reads the TV's EDID).

## The problem

Turning the TV (here behind a Sony AV receiver) off and on sometimes left the
box with:

- "unsupported signal" on the TV,
- no EDID (`/sys/class/drm/card0-HDMI-A-1/edid` empty), so a fallback mode
  (1920x1080 at 59.994 Hz, CVT timings) the TV doesn't accept,
- no CEC physical address (`f.f.f.f`), so the remote stopped working,
- every DDC transfer timing out (`i2ctransfer -y 1 w1@0x50 0x00 r16@0x50` →
  "Resource temporarily unavailable"),

until a reboot. The CEC log showed the EDID was read fine right after the TV
came on, and lost at a second hot-plug a few seconds later.

It is the wedge described in `dw_hdmi_i2c_unwedge()`
(`drivers/gpu/drm/bridge/synopsys/dw-hdmi.c`): a sink that powers up while
connected pulls SDA and SCL low and releases them without a STOP, and the
DesignWare I2C master hangs; its soft reset doesn't help. The driver recovers
by switching SDA to a GPIO driven low for 10 ms when a transfer times out,
but only if the device tree has an `unwedge` pinctrl state, which Rockchip
boards have and the Amlogic ones don't.

## The fix

`hdmi-ddc-unwedge.dts` adds that state to `hdmi_tx`: SDA (GPIOH_0) as a GPIO
output, low; SCL and HPD unchanged. After it, the kernel logs
`Attempting to unwedge stuck i2c bus` after the TV powers up and the EDID and
CEC come back by themselves.

It works with Armbian's 6.18 kernel and the [hwdec kernel](../hwdec-kernel/README.md).
`install.sh` adds it (the `home-media-player` package carries the source in
`/usr/share/home-media-player/overlays/`); by hand:

```sh
armbian-add-overlay /usr/share/home-media-player/overlays/hdmi-ddc-unwedge.dts
reboot
```

Check: `cat /sys/kernel/debug/pinctrl/pinctrl-handles` lists an `unwedge`
state for `ff600000.hdmi-tx`. Remove it by deleting `hdmi-ddc-unwedge` from
`user_overlays=` in `/boot/armbianEnv.txt`.

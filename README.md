# home-media-player

Turns an **ODROID-HC4** into a TV box that boots straight into a launcher on
HDMI and is driven with the **TV's own remote** over HDMI-CEC:

- **YouTube** – YouTube TV (youtube.com/tv) in Chromium.
- **Media** – browse SATA/USB disks, play videos and music (libmpv, with mpv's
  hotkeys and your own `input.conf`), view photos with a slideshow.
- **Power** – restart or shut down.
- **5.1 sound** – multichannel PCM to your TV or AV receiver.

It is the successor of [cec2media](https://github.com/hurelhuyag/cec2media)
(Raspberry Pi).

## What you need

- ODROID-HC4 with a microSD card (16 GB+), optionally SATA disks
- A TV with HDMI-CEC enabled (Sony: Bravia Sync, LG: SimpLink, Samsung:
  Anynet+, …); 1080p is enough
- A USB keyboard for the one-time setup, and another computer for SSH

## Setup

### 1. Flash Armbian

Download **Armbian Debian 13 (trixie) Minimal** for the ODROID-HC4 from
<https://www.armbian.com/odroid-hc4/> and write it to the microSD card with
[Armbian Imager](https://imager.armbian.com/), balenaEtcher or `dd`.

The Hardkernel Ubuntu image doesn't work: its 4.9 kernel has no DRM/KMS
graphics and no standard CEC device.

### 2. First boot (hold the button)

The HC4 ships Petitboot in its SPI flash, which can't boot Armbian. For the
first boot:

1. Insert the card, keep the power unplugged.
2. **Hold the small black button on the underside of the board** and plug in
   the power. Release it after ~5 seconds, when the blue LED blinks.
3. Wait 1–3 minutes. The screen shows boot messages, then a login prompt.

### 3. Remove Petitboot (once)

So the box boots by itself after every power cut, without the button:

1. Plug in a USB keyboard and power-cycle **without** the button. The
   Petitboot menu appears.
2. Choose **Exit to shell** and run:

   ```
   cat /proc/mtd
   flash_eraseall /dev/mtd0     # and the same for every other mtdN listed
   reboot
   ```

### 4. First login

From your computer: `ssh root@<ip of the box>` with password `1234`. Armbian
asks for a new root password and to create a user.

### 5. Install

```sh
curl -fsSL https://github.com/hurelhuyag/home-media-player/releases/latest/download/install.sh | sudo bash
```

The installer:

- sets kernel options in `/boot/armbianEnv.txt`: 1080p HDMI, and
  `pcie_aspm=off` so the SATA controller works
- keeps the CPU at its stock 1.908 GHz (`/etc/tmpfiles.d/hc4-cpufreq.conf`);
  the 2.0/2.1 GHz overclock steps Armbian allows were unstable on our board
- installs the packages from the latest release and their dependencies
  (Chromium, cage, mpv, …)
- builds the 5.1 HDMI audio modules for the running kernel (DKMS)
- asks to reboot

After the reboot the launcher appears on the TV and the box shows up as
**YoutubeTV** in the TV's input / CEC device list.

Options: `--version v0.1.0`, `--no-surround`, `--reboot`, `--local DIR`; pass
them as `... | sudo bash -s -- --reboot`.

## Using it

| Remote         | Launcher / lists | Video / music                     | Photos        |
|----------------|------------------|-----------------------------------|---------------|
| Arrows         | move             | ↑ info bar, ←/→ 10 s, ↓ playlist  | previous/next |
| OK             | open             | pause                             | slideshow     |
| Back / Exit    | back             | close                             | close         |
| Home           | launcher         | launcher                          | launcher      |
| ⏯ / ⏹          |                  | pause / close                     | slideshow     |
| ⏪ ⏩ / ⏮ ⏭      |                  | 30 s / previous, next file        | previous/next |
| Blue / Red     |                  | audio track / subtitles           |               |
| Green / Yellow |                  | stats / subtitles on-off          |               |
| Menu           | next sort order  | track list                        |               |

In YouTube the remote works as in YouTube's own TV app. **Home** always comes
back to the launcher.

In file lists, **Left** opens the menu on the left (sort by name or date
modified, shuffle, folders first or mixed with files) from anywhere in the
list, and **Right** goes back to the row you were on.

Videos and music resume where you stopped (mpv's `save-position-on-quit`,
saved every 30 s while playing, so also after a crash or power cut).

Disks: internal SATA disks and USB drives are listed under Media and mounted
when opened. To mount a disk at boot instead, add it to `/etc/fstab` (use
`nofail`) and it shows up there as well.

## Configuration

| File | What |
|------|------|
| `/etc/default/home-media-player` | HDMI mode, text size, folder bookmarks, YouTube options |
| `/etc/home-media-player/mpv/mpv.conf` | player options (subtitle/audio language, …) |
| `/etc/home-media-player/mpv/input.conf` | player keys, mpv syntax, on top of mpv's defaults |
| `/etc/home-media-player/mpv/scripts/` | mpv Lua/JS scripts |
| `/etc/default/cec2uinput` | name shown on the TV, CEC device type |

Apply changes with `systemctl restart home-media-player` (or
`cec2uinput`). The player reads its mpv files each time a video starts.

## Troubleshooting

- **No picture**: the box outputs 1080p60. Try another HDMI port or cable; with
  a 4K TV check that the port isn't limited by an "HDMI 2.0 / enhanced"
  setting. Logs: `journalctl -u home-media-player`.
- **Remote does nothing**: enable CEC on the TV and look for "YoutubeTV" in its
  device list. `journalctl -u cec2uinput` shows the CEC state; add `-v` to
  `CEC2UINPUT_ARGS` in `/etc/default/cec2uinput` to log every key. Some TVs
  forward more keys with `-t playback`.
- **Only stereo**: check `dkms status` lists `hmp-hdmi-multichannel` as
  installed for your kernel (`uname -r`) and reboot. After a kernel update,
  install the matching `linux-headers-current-meson64` and run
  `dkms autoinstall`. `hdmi-channel-test` (in `tools/`) plays noise on chosen
  channels to check speaker wiring.
- **Dolby/DTS passthrough** isn't possible yet with the mainline kernel; mpv
  decodes those formats to multichannel PCM instead. See
  [kernel/passthrough-research](kernel/passthrough-research/README.md).
- **SATA disk missing**: `pcie_aspm=off` must be on the kernel command line
  (`cat /proc/cmdline`).

## Uninstall

```sh
sudo apt purge home-media-player cec2uinput hmp-hdmi-multichannel-dkms
sudo cp /boot/armbianEnv.txt.before-home-media-player /boot/armbianEnv.txt
sudo systemctl set-default multi-user.target
```

## Development

| Directory | What |
|-----------|------|
| `kiosk/` | Flutter app, run full screen by [cage](https://github.com/cage-kiosk/cage) on tty1 |
| `cec2uinput/` | C daemon: registers on the CEC bus and turns remote presses into keys of a virtual keyboard (uinput); uses `/dev/cec0` directly, no libcec |
| `kernel/hdmi-multichannel/` | DKMS package with the patched sound modules for 5.1 over HDMI |
| `kernel/passthrough-research/` | notes and code from the passthrough attempt |
| `build/` | packaging and local build scripts |
| `tools/` | `hdmi-channel-test` |

**Releases** are built by GitHub Actions on arm64 runners: push a tag and the
workflow publishes the packages and `install.sh` as a release.

```sh
git tag v0.1.1 && git push origin v0.1.1
```

**Local builds**: Flutter can't cross-compile Linux apps to arm64, so the kiosk
is compiled over SSH on an arm64 Debian 13 machine (the HC4 works) and packaged
in a Docker image:

```sh
ssh root@HC4 bash -s < build/setup-build-host.sh   # once
BUILD_HOST=root@HC4 build/build.sh                 # -> dist/*.deb
build/deploy.sh root@HC4                           # install them on the box
```

`build/make-surround-test.sh` creates speaker-identification test files in
AC-3, E-AC-3, DTS and 6-channel FLAC.

## License

Apache License 2.0, like cec2media. The patched kernel module sources in
`kernel/` are GPL-2.0, as marked in each file.

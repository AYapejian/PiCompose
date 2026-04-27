# ara-kiosk-image

Custom Raspberry Pi 5 image for a Home Assistant voice-and-display kiosk.

Each image combines:

- A **Wayland kiosk** (cage + Chromium) that boots straight into a Home Assistant dashboard
- The Open Home Foundation **Linux Voice Assistant** (LVA) running in Docker, auto-discovered by Home Assistant via mDNS on port 6053
- A **Seeed reSpeaker XVF3800 USB-4MIC ARRAY** (no-XIAO variant, USB firmware) as the only audio device — hardware AEC, AGC, NS, and 360° beamforming, with 3.5 mm out driving external speakers

The image is a `.img.xz` flashable with `rpi-imager`. After flash, per-device customization is done by editing two files on the FAT32 partition (`/boot/firmware/kiosk.conf` and `/boot/firmware/lva.env`); no SSH session is required for fleet rollout.

This is a fork of [`florian-asche/PiCompose`](https://github.com/florian-asche/PiCompose); the original PiCompose docker-compose auto-deploy mechanism is preserved underneath.

## Hardware

- Raspberry Pi 5 (8 GB recommended; 4 GB works but Chromium memory pressure is closer to the edge)
- HDMI monitor for the kiosk display
- Seeed reSpeaker XVF3800 USB-4MIC ARRAY, **no-XIAO variant**, **USB firmware** (`respeaker_xvf3800_usb_dfu_firmware_v2.0.x.bin` — 2-channel, not the 6-channel raw-PDM variant)
- Powered speakers connected to the reSpeaker's 3.5 mm jack
- Pi 5 power supply (27 W official PSU recommended; the reSpeaker pulls real current over USB)

## Install

1. Download the latest `ara-kiosk-arm64.img.xz` from the [Releases page](../../releases) (once GitHub Actions is enabled — see CLAUDE.md).
2. Flash with [Raspberry Pi Imager](https://www.raspberrypi.com/software/). Use the customization wizard to set hostname, Wi-Fi, SSH key, and override the default `pi`/`raspberry` credentials. The hostname you set here becomes the LVA satellite's mDNS name in Home Assistant.
3. **Optional, but recommended:** mount the FAT32 partition and edit:
   - `/boot/firmware/kiosk.conf` — set the HA URL and any extra Chromium flags. See `kiosk.conf.example` next to it.
   - `/boot/firmware/lva.env` — pin LVA overrides like wake-word model. See `lva.env.example`.
4. Insert SD card, connect HDMI + USB reSpeaker + power. First boot takes ~3 minutes (LVA Docker image pull).
5. The LVA satellite auto-discovers in Home Assistant → Settings → Devices & Services as an ESPHome device.

## Per-device customization

After flashing, before booting (or any time later with the SD card mounted in any laptop), drop or edit these on the FAT32 partition:

| File on FAT32 | Purpose | Required? |
|---|---|---|
| `/boot/firmware/userconf.txt` | username : bcrypt-hash (Imager-managed) | Imager-managed |
| `/boot/firmware/wpa_supplicant.conf` | Wi-Fi credentials (Imager-managed) | Imager-managed |
| `/boot/firmware/kiosk.conf` | Kiosk URL + extra Chromium flags | Optional |
| `/boot/firmware/lva.env` | LVA overrides (wake word, image tag, debug, etc.) | Optional |

`lva-env-sync.service` runs before `picompose.service` on every boot and copies `/boot/firmware/lva.env` onto `/compose/lva/.env` if it exists.

## Build locally

`scripts/build-local.sh` is a thin wrapper around pi-gen's Docker build.

```bash
./scripts/build-local.sh
# Output lands in deploy/ara-kiosk-*.img.xz
```

Requires Linux (or WSL2) with Docker; native macOS won't work because pi-gen needs Linux kernel features. ~25 GB free disk, ~30–45 min for the first build.

See [CLAUDE.md](./CLAUDE.md) for the full design notes, post-flash verification checklist, and troubleshooting reference.

## Architecture

Stages run in order:

| Stage | What it does |
|---|---|
| `stage0`, `stage1`, `stage2` | Upstream pi-gen base (bootstrap, minimal, lite) |
| `01-stage-picompose` | Docker + docker-compose, picompose auto-deploy mechanism, PipeWire/WirePlumber/pipewire-pulse, lingering for `pi`, SSH on |
| `02-stage-audiodriver-xvf3800` | XVF3800 udev rules, WirePlumber priority pin, PipeWire 48 kHz clock override, HDMI audio off, `xvf_host` install, LED control stub |
| `03-stage-linux-voice-assistant` | LVA compose project at `/compose/lva/`, `lva-env-sync.service` for FAT32 overrides |
| `04-stage-kiosk` | cage + Chromium, tty1 autologin, `start-kiosk.sh` reading `/boot/firmware/kiosk.conf` |
| `05-stage-finish` | `XDG_RUNTIME_DIR` + `HOSTNAME` bashrc for `pi` and `root`, apt cache cleanup, SSH host key regen marker |

## Credits

- Forked from [`florian-asche/PiCompose`](https://github.com/florian-asche/PiCompose) — the docker-compose auto-deploy mechanism and PipeWire baseline are theirs
- Linux Voice Assistant from [OHF-Voice](https://github.com/OHF-Voice/linux-voice-assistant)
- Built with [pi-gen](https://github.com/RPi-Distro/pi-gen)
- reSpeaker XVF3800 firmware and `xvf_host` tooling from [Seeed](https://github.com/respeaker)

## License

[BSD 3-Clause](LICENSE) (matches upstream PiCompose).

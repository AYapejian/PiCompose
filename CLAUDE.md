# CLAUDE.md — ara-kiosk-image Build Instructions

You are working in a forked clone of `florian-asche/PiCompose`. Your job is to transform this fork into **`ara-kiosk-image`**, a custom Raspberry Pi 5 image that combines:

- A Wayland kiosk (cage + Chromium) showing a Home Assistant dashboard
- The Open Home Foundation **Linux Voice Assistant (LVA)** running in Docker
- A **reSpeaker XVF3800 USB-4MIC ARRAY** (the no-XIAO variant, USB firmware) as the only audio device
- All wired up to auto-discover with Home Assistant via mDNS / ESPHome protocol on port 6053

The end product is a `.img.xz` file built locally with pi-gen Docker (and later by GitHub Actions), flashable with `rpi-imager`, that boots straight into the kiosk + voice assistant with zero post-flash setup beyond per-device config files on the FAT32 partition.

---

## Table of contents

1. [Decisions already made — do not re-ask](#decisions-already-made--do-not-re-ask)
2. [Hardware & environment context](#hardware--environment-context)
3. [What's already in this repo (upstream PiCompose)](#whats-already-in-this-repo-upstream-picompose)
4. [Pre-flight verification](#pre-flight-verification)
5. [Step 1 — Clean up unused upstream stages](#step-1--clean-up-unused-upstream-stages)
6. [Step 2 — Top-level `config` file](#step-2--top-level-config-file)
7. [Step 3 — Top-level `stage-list` file](#step-3--top-level-stage-list-file)
8. [Step 4 — Keep `01-stage-picompose` as-is, audit for `pi` user assumptions](#step-4--keep-01-stage-picompose-as-is-audit-for-pi-user-assumptions)
9. [Step 5 — Create `02-stage-audiodriver-xvf3800/`](#step-5--create-02-stage-audiodriver-xvf3800)
10. [Step 6 — Rework `03-stage-linux-voice-assistant/`](#step-6--rework-03-stage-linux-voice-assistant)
11. [Step 7 — Create `04-stage-kiosk/`](#step-7--create-04-stage-kiosk)
12. [Step 8 — Rename existing `04-stage-finish/` → `05-stage-finish/`](#step-8--rename-existing-04-stage-finish--05-stage-finish)
13. [Step 9 — Disable GitHub Actions workflow (keep file, comment out triggers)](#step-9--disable-github-actions-workflow-keep-file-comment-out-triggers)
14. [Step 10 — Update `README.md`](#step-10--update-readmemd)
15. [Local build instructions](#local-build-instructions)
16. [Post-flash verification checklist](#post-flash-verification-checklist)
17. [Per-device customization (FAT32 partition)](#per-device-customization-fat32-partition)
18. [Troubleshooting reference](#troubleshooting-reference)
19. [Future enhancements](#future-enhancements)

---

## Decisions already made — do not re-ask

These were resolved in design conversation; you do not need to re-prompt the user about them:

1. **User account:** Stay with PiCompose's default `pi` user (UID/GID 1000). Don't rename to `ara`. Default password `raspberry` is overridden via Imager at flash time.
2. **HA URL:** Primary is the LAN address `https://192.168.1.210:8123` with Chromium's `--ignore-certificate-errors` flag. Documented Nabu Casa fallback URL goes in `kiosk.conf.example` for off-LAN kiosks.
3. **GitHub Actions:** Disabled initially (file present but workflow_dispatch only, no triggers). User builds locally with pi-gen Docker first, enables Actions later.
4. **LVA Docker image:** Pull from upstream `ghcr.io/ohf-voice/linux-voice-assistant:latest`. This is correct — that's their public, intended-for-consumption image. Do NOT fork it. The OS image *we* build goes to the user's own GitHub releases when Actions is enabled.
5. **SD card per-device config trust model:** Anyone with physical SD card access can edit `kiosk.conf` and `.env`. That's acceptable for a home/lab fleet.
6. **Upstream PR:** Not now. Once this works, the user will manually decide whether to PR the XVF3800 stage back to `florian-asche/PiCompose`.
7. **xvf_host LED control:** Install the `xvf_host` Python tool in the audio stage so it's available. Add a stub `xvf3800-led` systemd service (disabled by default). Wiring LED feedback to LVA wake-word state is documented as a follow-up enhancement, not part of this initial build.

---

## Hardware & environment context

- **Target SBC:** Raspberry Pi 5 (8GB), 64-bit (`arm64`), HDMI to a monitor for the kiosk.
- **Audio device:** Seeed reSpeaker XVF3800 USB-4MIC ARRAY, **no-XIAO variant** (the bare board without the soldered ESP32-S3). It must be running the USB firmware variant `respeaker_xvf3800_usb_dfu_firmware_v2.0.x.bin` — the **2-channel** version, not the 6-channel raw-PDM version. Channel 0 = processed conference audio, channel 1 = ASR-tuned. Hardware does AEC, AGC, noise suppression, and 360° beamforming.
- **DO NOT enable software AGC/NS in LVA.** Hardware already does it, doubling up degrades quality.
- **Output path:** XVF3800 3.5mm jack drives external speakers. HDMI audio is disabled at the device-tree level (`dtoverlay=vc4-kms-v3d,noaudio`) so PipeWire sees the reSpeaker as the only sink and AEC reference is correct.
- **HA endpoint:** Default `https://192.168.1.210:8123`. Nabu Casa relay URL is `https://lgthcmaysohssmsk9tvq7pz96zocz7oa.ui.nabu.casa/` (documented as alternative).
- **User:** `pi` (UID 1000, GID 1000). PiCompose's default.
- **Locale/TZ:** `en_US.UTF-8`, `America/New_York`, US keyboard.
- **Architecture:** `arm64` (aarch64). The Pi 5 is 64-bit only.

---

## What's already in this repo (upstream PiCompose)

This is a fork of `florian-asche/PiCompose`. Upstream provides:

- `01-stage-picompose/` — base stage: Docker, docker-compose-plugin, picompose auto-deploy mechanism, PipeWire packages, SSH enabled, default `pi` user
- `02-stage-audiodriver-2michat-v1/` — for ReSpeaker 2-Mic HAT (NOT our hardware)
- `02-stage-audiodriver-respeaker_lite/` — for ReSpeaker Lite (NOT our hardware)
- `03-stage-linux-voice-assistant/` — LVA via docker-compose, currently configured for the upstream hardware (2-Mic HAT or ReSpeaker Lite)
- `04-stage-finish/` — cleanup + image export
- `.github/workflows/` — pi-gen GitHub Actions builds

We are going to:
1. **Delete** the two unused `02-stage-audiodriver-*` directories
2. **Add a new** `02-stage-audiodriver-xvf3800/` for our reSpeaker
3. **Rework** `03-stage-linux-voice-assistant/` for XVF3800-appropriate LVA config (no software AGC/NS, host networking, PulseAudio socket mount)
4. **Add a new** `04-stage-kiosk/` for cage + Chromium
5. **Rename** the existing `04-stage-finish/` to `05-stage-finish/`
6. Update the top-level `config` and `stage-list`
7. Disable the GitHub Actions workflow until local build is validated
8. Update `README.md` for the fork

---

## Pre-flight verification

Run these checks before making any changes. Fix any discrepancies and report back if upstream layout has shifted from what's described above:

```bash
# 1. Confirm we're in a PiCompose fork
[ -d 01-stage-picompose ] && echo "OK: PiCompose layout detected" || \
    echo "ERROR: not a PiCompose fork"

# 2. Verify expected upstream stage directories
ls -1d 0[1-4]-stage-* 2>/dev/null

# 3. Verify the LVA Docker image exists on GHCR
curl -sSL "https://ghcr.io/v2/ohf-voice/linux-voice-assistant/tags/list" \
    -H "Authorization: Bearer $(curl -s 'https://ghcr.io/token?scope=repository:ohf-voice/linux-voice-assistant:pull' | jq -r .token)" \
    | jq -r '.tags | sort | .[]' | head -20

# 4. Confirm pi-gen Docker image is pullable for local builds
docker pull --quiet ghcr.io/rpi-distro/pi-gen:bookworm-arm64 2>/dev/null \
    || echo "Will use upstream pi-gen build-docker.sh instead of prebuilt image"

# 5. Verify the upstream picompose script references 'pi' user
grep -n "\bpi\b" 01-stage-picompose/files/usr/local/bin/picompose 2>/dev/null || \
    grep -rn "/home/pi" 01-stage-picompose/ 2>/dev/null | head
```

If anything fails, **stop and report**. Don't try to work around upstream layout drift silently.

---

## Step 1 — Clean up unused upstream stages

```bash
git rm -rf 02-stage-audiodriver-2michat-v1
git rm -rf 02-stage-audiodriver-respeaker_lite
```

Commit this as its own commit: `git commit -m "Remove unused 2-Mic HAT and ReSpeaker Lite stages"`.

---

## Step 2 — Top-level `config` file

This file is sourced by pi-gen at the start of the build. Replace any existing `config` at the repo root with this exact content:

**File:** `config`

```bash
# pi-gen top-level configuration for ara-kiosk-image

IMG_NAME='ara-kiosk'
RELEASE='bookworm'
ARCH='arm64'

# Hostname can be overridden by Imager at flash time
TARGET_HOSTNAME='kiosk'

# Locale, timezone, keyboard
LOCALE_DEFAULT='en_US.UTF-8'
TIMEZONE_DEFAULT='America/New_York'
KEYBOARD_KEYMAP='us'
KEYBOARD_LAYOUT='English (US)'

# Default first user — override with Imager at flash time
FIRST_USER_NAME='pi'
FIRST_USER_PASS='raspberry'
DISABLE_FIRST_BOOT_USER_RENAME=1

# SSH on by default; user adds their pubkey via Imager
ENABLE_SSH=1
PUBKEY_ONLY_SSH=0

# Wi-Fi (US regulatory domain)
WPA_COUNTRY='US'

# Image compression
DEPLOY_COMPRESSION='xz'
COMPRESSION_LEVEL=6

# Stage execution order — see ./stage-list
# (pi-gen reads STAGE_LIST from here OR a separate stage-list file at root)
```

---

## Step 3 — Top-level `stage-list` file

pi-gen supports a `stage-list` file at the repo root. Create one with explicit ordering:

**File:** `stage-list`

```
stage0
stage1
stage2
./01-stage-picompose
./02-stage-audiodriver-xvf3800
./03-stage-linux-voice-assistant
./04-stage-kiosk
./05-stage-finish
```

Note: `stage0`, `stage1`, `stage2` are the upstream pi-gen stages (bootstrap, minimal, lite). pi-gen's Docker build clones `RPi-Distro/pi-gen` and runs these from inside its image.

---

## Step 4 — Keep `01-stage-picompose` as-is, audit for `pi` user assumptions

Don't rewrite this stage. Just verify the upstream stage:

1. References `/home/pi` consistently (no `/home/ara`)
2. The `picompose.service` runs as root (it has to, for Docker)
3. The `picompose` script reads from `/boot/firmware/compose/`

```bash
# Verify pi user is wired through correctly
grep -rn "FIRST_USER_NAME\|/home/pi\|user pi" 01-stage-picompose/ | head -30
```

If anything looks divergent from the upstream PiCompose README's described behavior, **stop and report** before continuing.

**One small modification needed:** the upstream `picompose` script may not wait for the user PipeWire/Pulse socket to be live before deploying compose stacks that mount `/run/user/1000/pulse`. We need that wait, because LVA's container will fail to start if the socket isn't there.

Patch `01-stage-picompose/files/usr/local/bin/picompose` (or wherever the script lives — find it first with `find 01-stage-picompose -name picompose -type f`):

Add this block **immediately after** the existing "Wait for network" block, **before** the `for project_dir in ...` loop:

```bash
# Wait for the pi user's PipeWire/Pulse socket to be available.
# Some compose projects (LVA) mount this socket and need it live.
PULSE_SOCK="/run/user/1000/pulse/native"
for i in $(seq 1 30); do
    [ -S "$PULSE_SOCK" ] && break
    sleep 2
done
if [ ! -S "$PULSE_SOCK" ]; then
    echo "[$(date -Is)] WARNING: $PULSE_SOCK not available after 60s; continuing anyway"
fi
```

The `loginctl enable-linger pi` we'll set in stage 02 ensures the user session (and therefore the Pulse socket) comes up at boot without a login.

---

## Step 5 — Create `02-stage-audiodriver-xvf3800/`

Create the directory and all files below. Make `00-run.sh` executable (`chmod +x`).

### `02-stage-audiodriver-xvf3800/00-packages`

Packages to install in this stage:

```
pipewire
pipewire-audio
pipewire-alsa
pipewire-pulse
wireplumber
libspa-0.2-bluetooth
alsa-utils
dfu-util
usbutils
python3-pip
python3-venv
```

### `02-stage-audiodriver-xvf3800/00-run.sh`

```bash
#!/bin/bash -e

USER_HOME="/home/${FIRST_USER_NAME}"
USER_UID="1000"

# udev rules: allow `pi` (via plugdev/uaccess) to flash firmware via dfu-util
# without sudo, and to access XVF3800 USB control endpoints
install -v -m 644 files/etc/udev/rules.d/99-xvf3800.rules \
    "${ROOTFS_DIR}/etc/udev/rules.d/99-xvf3800.rules"

# PipeWire + WirePlumber configs for the user
install -v -d -o "${USER_UID}" -g "${USER_UID}" \
    "${ROOTFS_DIR}${USER_HOME}/.config/pipewire/pipewire.conf.d"
install -v -d -o "${USER_UID}" -g "${USER_UID}" \
    "${ROOTFS_DIR}${USER_HOME}/.config/wireplumber/wireplumber.conf.d"

install -v -m 644 -o "${USER_UID}" -g "${USER_UID}" \
    files/home/pi/.config/pipewire/pipewire.conf.d/10-respeaker.conf \
    "${ROOTFS_DIR}${USER_HOME}/.config/pipewire/pipewire.conf.d/10-respeaker.conf"

install -v -m 644 -o "${USER_UID}" -g "${USER_UID}" \
    files/home/pi/.config/wireplumber/wireplumber.conf.d/51-respeaker.conf \
    "${ROOTFS_DIR}${USER_HOME}/.config/wireplumber/wireplumber.conf.d/51-respeaker.conf"

# Disable HDMI audio in the device tree so reSpeaker is the only sink
# and the XVF3800's onboard AEC reference signal stays correct
sed -i 's|^dtoverlay=vc4-kms-v3d.*|dtoverlay=vc4-kms-v3d,noaudio|' \
    "${ROOTFS_DIR}/boot/firmware/config.txt"

# xvf_host: install Seeed's XMOS USB control tool for LED ring, DOA, DSP tuning.
# Installed system-wide via pip with --break-system-packages because Bookworm
# enforces PEP 668 on the system Python. This is acceptable for a purpose-built
# image where we control all Python state.
on_chroot << 'CHROOT_EOF'
pip3 install --break-system-packages --no-cache-dir xmos-xvf-host || \
    pip3 install --break-system-packages --no-cache-dir 'git+https://github.com/respeaker/reSpeaker_XVF3800_USB_4MIC_ARRAY.git#subdirectory=xvf_host_app'
CHROOT_EOF

# Stub LED control daemon (disabled by default) — wire up to LVA later
install -v -m 755 files/usr/local/bin/xvf3800-led \
    "${ROOTFS_DIR}/usr/local/bin/xvf3800-led"
install -v -m 644 files/etc/systemd/system/xvf3800-led.service \
    "${ROOTFS_DIR}/etc/systemd/system/xvf3800-led.service"

# Group memberships and lingering
on_chroot << EOF
usermod -aG audio,video,render,plugdev ${FIRST_USER_NAME}
loginctl enable-linger ${FIRST_USER_NAME}
EOF

# Note: We do NOT enable xvf3800-led.service. User enables it after configuring
# their LED preferences.
```

### `02-stage-audiodriver-xvf3800/files/etc/udev/rules.d/99-xvf3800.rules`

```
# Seeed reSpeaker XVF3800 USB-4MIC ARRAY (no-XIAO variant)
# https://wiki.seeedstudio.com/respeaker_xvf3800_introduction/

# DFU mode (XMOS firmware update)
SUBSYSTEM=="usb", ATTR{idVendor}=="2886", ATTR{idProduct}=="001a", \
    MODE="0660", GROUP="plugdev", TAG+="uaccess"

# Normal USB Audio Class + control mode (XMOS XVF3800)
# XMOS uses VID 20b1 for production audio devices
SUBSYSTEM=="usb", ATTR{idVendor}=="20b1", \
    MODE="0660", GROUP="plugdev", TAG+="uaccess"
```

### `02-stage-audiodriver-xvf3800/files/home/pi/.config/pipewire/pipewire.conf.d/10-respeaker.conf`

```conf
# PipeWire clock config tuned for XVF3800 USB Audio Class 2.0 device.
# Allow native 16 kHz so the graph runs at the device rate when only
# the reSpeaker is active — avoids resampling overhead on capture.

context.properties = {
    default.clock.rate          = 48000
    default.clock.allowed-rates = [ 16000 48000 ]
    default.clock.quantum       = 1024
    default.clock.min-quantum   = 32
    default.clock.max-quantum   = 8192
}
```

### `02-stage-audiodriver-xvf3800/files/home/pi/.config/wireplumber/wireplumber.conf.d/51-respeaker.conf`

```conf
# Pin the reSpeaker as the highest-priority sink and source so it stays
# the default device even if other USB audio gets plugged in temporarily.

monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_.*reSpeaker.*" }
    ]
    actions = {
      update-props = {
        priority.driver  = 2000
        priority.session = 2000
        node.description = "reSpeaker XVF3800"
      }
    }
  }
]
```

### `02-stage-audiodriver-xvf3800/files/usr/local/bin/xvf3800-led`

A stub control daemon. Initially just demonstrates that `xvf_host` works; the user wires it to LVA wake-word state later.

```bash
#!/usr/bin/env bash
# xvf3800-led — stub LED control daemon for XVF3800
#
# This is a placeholder. By default this script just sets a steady "idle"
# color on boot and exits. A future enhancement (see CLAUDE.md) wires this
# up to LVA's wake-word state via the ESPHome API or a local IPC.
#
# To use the LEDs interactively:
#   xvf_host --vendor-id 0x20b1 --product-id <PID> SET_LED_RING_COLOR <r> <g> <b>
#
# Find PID with: lsusb | grep XMOS

set -euo pipefail

# Wait for the device to enumerate after boot
for i in $(seq 1 30); do
    if lsusb | grep -qi 'xmos\|xvf'; then
        break
    fi
    sleep 1
done

# Set a dim cyan idle color (reuses xvf_host's default protocol)
# Adjust the command below once you've inspected `xvf_host --help` on the
# actual hardware to confirm the LED control verb name.
xvf_host SET_LED_RING_EFFECT 1 || \
    echo "xvf3800-led: xvf_host LED command not yet validated for this firmware"

exit 0
```

### `02-stage-audiodriver-xvf3800/files/etc/systemd/system/xvf3800-led.service`

```ini
[Unit]
Description=XVF3800 LED control (stub)
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xvf3800-led
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
```

---

## Step 6 — Rework `03-stage-linux-voice-assistant/`

Inspect what's there first:

```bash
ls -la 03-stage-linux-voice-assistant/
cat 03-stage-linux-voice-assistant/00-run.sh 2>/dev/null
find 03-stage-linux-voice-assistant/files -type f 2>/dev/null
```

**Replace** `03-stage-linux-voice-assistant/00-run.sh` with:

```bash
#!/bin/bash -e

# Drop LVA compose project in /boot/firmware/compose/lva so picompose.service
# auto-deploys it on first boot.

install -v -d "${ROOTFS_DIR}/boot/firmware/compose/lva"

install -v -m 644 files/boot/firmware/compose/lva/docker-compose.yml \
    "${ROOTFS_DIR}/boot/firmware/compose/lva/docker-compose.yml"
install -v -m 644 files/boot/firmware/compose/lva/picompose.conf \
    "${ROOTFS_DIR}/boot/firmware/compose/lva/picompose.conf"
install -v -m 644 files/boot/firmware/compose/lva/.env \
    "${ROOTFS_DIR}/boot/firmware/compose/lva/.env"
```

**Delete any existing** `files/` subdirectory in this stage and recreate from scratch with the contents below.

### `03-stage-linux-voice-assistant/files/boot/firmware/compose/lva/docker-compose.yml`

```yaml
# Linux Voice Assistant — Open Home Foundation
# https://github.com/OHF-Voice/linux-voice-assistant
#
# Speaks the ESPHome protocol on port 6053; auto-discovered by Home Assistant
# via mDNS. On-device wake word detection via openWakeWord (default model:
# okay_nabu).
#
# IMPORTANT for XVF3800 hardware:
#   The reSpeaker already does AGC, noise suppression, and AEC in hardware.
#   Do NOT enable LVA_MIC_AUTO_GAIN or LVA_MIC_NOISE_SUPPRESSION here, or
#   you'll double-process the audio and degrade STT accuracy.

services:
  linux-voice-assistant:
    image: ghcr.io/ohf-voice/linux-voice-assistant:latest
    container_name: lva
    restart: unless-stopped

    # Host networking required for:
    #   - ESPHome API (port 6053) to be reachable from HA
    #   - mDNS announcement so HA auto-discovers this satellite
    network_mode: host

    environment:
      - LVA_NAME=${LVA_NAME:-kiosk}
      - LVA_WAKE_MODEL=${LVA_WAKE_MODEL:-okay_nabu}
      - LVA_PORT=6053
      # XVF3800 hardware does AGC + NS + AEC; keep these OFF
      - LVA_MIC_AUTO_GAIN=0
      - LVA_MIC_NOISE_SUPPRESSION=0
      # Use the pi user's PulseAudio socket (proxied to PipeWire)
      - PULSE_SERVER=unix:/run/user/1000/pulse/native

    volumes:
      # PulseAudio/PipeWire socket for audio I/O
      - /run/user/1000/pulse:/run/user/1000/pulse:ro
      # Stable machine-id for ESPHome mDNS announcement
      - /etc/machine-id:/etc/machine-id:ro
      # Persistent state (preferences, downloaded wake words)
      - lva-data:/data

    # Direct ALSA fallback if PulseAudio is unavailable
    devices:
      - /dev/snd:/dev/snd

    # Bookworm group IDs: audio=29, video=44, render=109
    group_add:
      - "29"
      - "44"
      - "109"

volumes:
  lva-data:
```

### `03-stage-linux-voice-assistant/files/boot/firmware/compose/lva/picompose.conf`

```bash
# picompose deployment policy for LVA
BOOT_ENABLED=true
BOOT_IMAGE_PULL=true

# Weekly auto-update Sunday 4am — pull latest LVA image and restart
CRON_ENABLED=true
CRON_SCHEDULE="0 4 * * 0"
CRON_IMAGE_PULL=true
```

### `03-stage-linux-voice-assistant/files/boot/firmware/compose/lva/.env`

This is editable per-device on the FAT32 partition.

```bash
# Per-device LVA configuration
# Edit on the FAT32 partition before first boot if you want a non-default name.

# Friendly name announced to Home Assistant via mDNS
LVA_NAME=kiosk

# Wake word model. Built-in options:
#   okay_nabu (default, most reliable)
#   hey_jarvis
#   alexa
# Custom .tflite models can be added — see LVA docs.
LVA_WAKE_MODEL=okay_nabu
```

---

## Step 7 — Create `04-stage-kiosk/`

Create the directory and all files below. Make `00-run.sh` executable.

### `04-stage-kiosk/00-packages`

```
cage
seatd
xwayland
chromium-browser
fonts-dejavu
fonts-liberation
netcat-openbsd
```

### `04-stage-kiosk/00-run.sh`

```bash
#!/bin/bash -e

USER_HOME="/home/${FIRST_USER_NAME}"
USER_UID="1000"

# Auto-login on tty1 (kiosk session)
install -v -d "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d"
install -v -m 644 files/etc/systemd/system/getty@tty1.service.d/autologin.conf \
    "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/autologin.conf"

# .bash_profile auto-launches cage on tty1
install -v -m 644 -o "${USER_UID}" -g "${USER_UID}" \
    files/home/pi/.bash_profile \
    "${ROOTFS_DIR}${USER_HOME}/.bash_profile"

# Kiosk launcher script
install -v -d -o "${USER_UID}" -g "${USER_UID}" \
    "${ROOTFS_DIR}${USER_HOME}/.config/kiosk"
install -v -m 755 -o "${USER_UID}" -g "${USER_UID}" \
    files/home/pi/.config/kiosk/start-kiosk.sh \
    "${ROOTFS_DIR}${USER_HOME}/.config/kiosk/start-kiosk.sh"

# Per-device kiosk URL config — drop on FAT32 to override defaults
install -v -m 644 files/boot/firmware/kiosk.conf.example \
    "${ROOTFS_DIR}/boot/firmware/kiosk.conf.example"

# seatd group membership (cage needs seat access)
on_chroot << EOF
usermod -aG seat ${FIRST_USER_NAME} 2>/dev/null || groupadd seat && usermod -aG seat ${FIRST_USER_NAME}
systemctl enable seatd
EOF
```

### `04-stage-kiosk/files/etc/systemd/system/getty@tty1.service.d/autologin.conf`

```ini
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I $TERM
```

### `04-stage-kiosk/files/home/pi/.bash_profile`

```bash
# auto-start kiosk on tty1 only
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec cage -s -- ~/.config/kiosk/start-kiosk.sh
fi
```

### `04-stage-kiosk/files/home/pi/.config/kiosk/start-kiosk.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Per-device override (drop /boot/firmware/kiosk.conf at flash time)
CONF=/boot/firmware/kiosk.conf
KIOSK_URL="https://192.168.1.210:8123"
EXTRA_FLAGS=""

# shellcheck source=/dev/null
[ -f "$CONF" ] && source "$CONF"

# Wait for HA to be reachable
host="${KIOSK_URL#https://}"; host="${host#http://}"; host="${host%%[/:]*}"
port="$(echo "$KIOSK_URL" | sed -nE 's|.*:([0-9]+).*|\1|p')"
case "$KIOSK_URL" in
    https://*) port="${port:-443}" ;;
    http://*)  port="${port:-80}"  ;;
    *)         port="${port:-443}" ;;
esac

echo "kiosk: waiting for $host:$port"
until nc -z "$host" "$port" 2>/dev/null; do sleep 1; done
echo "kiosk: $host:$port reachable"

# shellcheck disable=SC2086
exec chromium-browser \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --disable-features=TranslateUI \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --check-for-update-interval=31536000 \
  --no-first-run \
  --start-fullscreen \
  --autoplay-policy=no-user-gesture-required \
  --ozone-platform=wayland \
  --enable-features=VaapiVideoDecoder \
  --ignore-certificate-errors \
  --test-type \
  $EXTRA_FLAGS \
  "$KIOSK_URL"
```

The `--ignore-certificate-errors --test-type` combo silences Chromium's "you are using an unsupported flag" banner that otherwise appears on top of the kiosk content. Without `--test-type`, the warning chip stays visible.

### `04-stage-kiosk/files/boot/firmware/kiosk.conf.example`

```bash
# Per-device kiosk configuration
# Copy this file to /boot/firmware/kiosk.conf and edit before first boot,
# or after first boot from any laptop with the SD card mounted.

# === Default (LAN) ===
# Lowest-latency option when this kiosk is on the same LAN as Home Assistant.
# --ignore-certificate-errors handles HA's self-signed cert.
KIOSK_URL=https://192.168.1.210:8123

# === Alternative: Nabu Casa relay ===
# Use this if the kiosk is OFF the home LAN. Adds 30-100ms relay latency
# per request, plus all websocket entity updates flow through the relay.
# Trades latency for not needing --ignore-certificate-errors.
# KIOSK_URL=https://lgthcmaysohssmsk9tvq7pz96zocz7oa.ui.nabu.casa/

# === Alternative: HTTP for dev ===
# If you've configured HA on plain HTTP for development.
# KIOSK_URL=http://192.168.1.210:8123

# === Extra Chromium flags (optional) ===
# Uncomment to add per-device flags. Useful for kiosk-specific dashboard URLs:
#   /lovelace/kiosk-livingroom
#   /lovelace-mobile/0
# EXTRA_FLAGS="--app=https://192.168.1.210:8123/lovelace/kiosk"
```

---

## Step 8 — Rename existing `04-stage-finish/` → `05-stage-finish/`

```bash
git mv 04-stage-finish 05-stage-finish
```

Verify `05-stage-finish/EXPORT_IMAGE` exists (it's the marker file that tells pi-gen to export this stage as the final `.img`):

```bash
[ -f 05-stage-finish/EXPORT_IMAGE ] && echo "OK" || \
    touch 05-stage-finish/EXPORT_IMAGE
```

If `EXPORT_IMAGE` was empty in the upstream, leave it empty. If it had `IMG_SUFFIX=...`, leave that.

Verify it has a `00-run.sh` that does cleanup. If not, create:

**File:** `05-stage-finish/00-run.sh`

```bash
#!/bin/bash -e

on_chroot << 'EOF'
# Regenerate machine-id at first boot (don't bake one into the image)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Aggressive cleanup to shrink final image
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*
rm -rf /root/.cache /home/pi/.cache 2>/dev/null || true
EOF
```

---

## Step 9 — Disable GitHub Actions workflow (keep file, comment out triggers)

Find the workflow file:

```bash
ls -la .github/workflows/
```

Whatever is there (likely `build-image.yml` or similar from upstream), **modify the triggers section** so it only runs on `workflow_dispatch` (manual). Do not delete the file — we'll re-enable it later.

Replace the entire workflow file with this. Update `image-name` and stage list to match our fork:

**File:** `.github/workflows/build-image.yml`

```yaml
name: Build Image

# DISABLED until local build is validated. Re-enable by uncommenting the
# 'push' trigger below. See CLAUDE.md → "Local build instructions" first.
on:
  workflow_dispatch: {}
  # push:
  #   tags: [ 'v*' ]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Build image with pi-gen
        uses: usimd/pi-gen-action@v1
        with:
          image-name: ara-kiosk
          stage-list: stage0 stage1 stage2 ./01-stage-picompose ./02-stage-audiodriver-xvf3800 ./03-stage-linux-voice-assistant ./04-stage-kiosk ./05-stage-finish
          release: bookworm
          pi-gen-version: arm64
          compression: xz
          compression-level: 6
          enable-ssh: 1
          username: pi
          password: raspberry
          hostname: kiosk
          locale: en_US.UTF-8
          timezone: America/New_York
          keyboard-keymap: us
          wpa-country: US
          increase-runner-disk-size: true

      - name: Upload to release
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          files: |
            deploy/*.img.xz
            deploy/*.img.xz.sha256
```

**Note for the user:** When this workflow is enabled and a tag like `v1.0.0` is pushed, the `.img.xz` is published to **the user's own** GitHub releases. Nothing is pushed to upstream `florian-asche/PiCompose` or to `OHF-Voice/linux-voice-assistant`.

---

## Step 10 — Update `README.md`

Replace the existing `README.md` (which describes upstream PiCompose) with one that describes this fork. Use this as the baseline:

**File:** `README.md`

```markdown
# ara-kiosk-image

Custom Raspberry Pi 5 image for a Home Assistant voice-and-display kiosk.

Combines:
- **Wayland kiosk** (cage + Chromium) showing a Home Assistant dashboard
- **Linux Voice Assistant** (OHF-Voice/linux-voice-assistant) running in Docker
- **reSpeaker XVF3800 USB-4MIC ARRAY** as the audio device, with hardware AEC

## Hardware

- Raspberry Pi 5 (8GB recommended)
- HDMI monitor for the kiosk display
- Seeed reSpeaker XVF3800 USB-4MIC ARRAY (no-XIAO variant), USB firmware
- Speakers connected to the reSpeaker's 3.5mm jack

## Install

1. Download the latest `ara-kiosk-arm64.img.xz` from the [Releases page](../../releases).
2. Flash with [Raspberry Pi Imager](https://www.raspberrypi.com/software/). Use the customization wizard to set hostname, Wi-Fi, SSH key, and override the default `pi`/`raspberry` credentials.
3. Optional: Mount the FAT32 partition and edit `/boot/firmware/kiosk.conf` to point at your HA URL (default `https://192.168.1.210:8123`). See `kiosk.conf.example`.
4. Optional: Edit `/boot/firmware/compose/lva/.env` to set the LVA satellite name and wake word.
5. Insert SD card, connect HDMI + USB reSpeaker + power. First boot takes ~3 minutes (Docker pull of LVA image).
6. The kiosk satellite auto-discovers in Home Assistant via mDNS.

## Build locally

```bash
git clone --depth 1 https://github.com/RPi-Distro/pi-gen.git pi-gen-build
cd pi-gen-build
ln -s ../config ./config
ln -s ../stage-list ./stage-list
ln -s ../01-stage-picompose .
ln -s ../02-stage-audiodriver-xvf3800 .
ln -s ../03-stage-linux-voice-assistant .
ln -s ../04-stage-kiosk .
ln -s ../05-stage-finish .
sudo ./build-docker.sh
# Output: deploy/*.img.xz
```

See [CLAUDE.md](./CLAUDE.md) for full build/development notes.

## Per-device customization

After flashing, before booting (or any time with SD card mounted):

| File on FAT32 partition | Purpose |
|---|---|
| `/boot/firmware/kiosk.conf` | Kiosk URL, extra Chromium flags |
| `/boot/firmware/compose/lva/.env` | LVA satellite name, wake word |
| `/boot/firmware/userconf.txt` | (Imager-managed) hostname, user, password |

## Credits

- Based on [`florian-asche/PiCompose`](https://github.com/florian-asche/PiCompose)
- Linux Voice Assistant from [OHF-Voice](https://github.com/OHF-Voice/linux-voice-assistant)
- Built with [pi-gen](https://github.com/RPi-Distro/pi-gen)
```

---

## Local build instructions

After all the changes are in, build locally to validate before enabling GitHub Actions.

### Prerequisites

- A Linux host (or WSL2). Native macOS doesn't work — pi-gen requires Linux kernel features.
- Docker installed and running.
- ~25 GB free disk space.
- ~30–45 minutes for the first build (subsequent builds with caching are faster).

### Build script

Create a one-shot build helper at the repo root:

**File:** `scripts/build-local.sh`

```bash
#!/usr/bin/env bash
# Local build using pi-gen's Docker mode.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${REPO_ROOT}/.pi-gen-work"

# Clone pi-gen if not present
if [ ! -d "${WORK_DIR}" ]; then
    git clone --depth 1 --branch arm64 \
        https://github.com/RPi-Distro/pi-gen.git "${WORK_DIR}"
fi

cd "${WORK_DIR}"

# Symlink our stages and config into pi-gen's working dir
for f in config stage-list \
         01-stage-picompose \
         02-stage-audiodriver-xvf3800 \
         03-stage-linux-voice-assistant \
         04-stage-kiosk \
         05-stage-finish; do
    ln -sfn "${REPO_ROOT}/${f}" "./${f}"
done

# Mark unused upstream stages so they're skipped
for s in stage3 stage4 stage5; do
    touch "${s}/SKIP" "${s}/SKIP_IMAGES" 2>/dev/null || true
done

echo "==> Building. This will take 30-45 minutes on first run."
sudo PRESERVE_CONTAINER=1 ./build-docker.sh

echo "==> Output:"
ls -lh "${WORK_DIR}/deploy/"

echo
echo "==> Copy to repo deploy/ for convenience:"
mkdir -p "${REPO_ROOT}/deploy"
cp -v "${WORK_DIR}/deploy/"*.img.xz "${REPO_ROOT}/deploy/" 2>/dev/null || true
```

Make executable: `chmod +x scripts/build-local.sh`.

### Run it

```bash
./scripts/build-local.sh
```

**Watch for these failure modes:**

1. **`apt-get install` fails inside chroot** — usually a typo in `00-packages`. Re-check the file.
2. **`install: cannot create regular file ...: No such file or directory`** — a `00-run.sh` is `install`-ing a file from `files/` that doesn't exist. Verify the source path.
3. **`xvf_host` install fails in stage 02** — the pip package name might differ. Try inspecting:
   ```bash
   docker run --rm python:3.11-slim pip search xvf_host  # or xvf3800
   ```
   If neither pip name works, fall back to cloning Seeed's repo and installing from source — the script already has a fallback line for this.
4. **Out of disk space** — pi-gen needs ~25GB. Clean `.pi-gen-work/work/` between failed builds.

### Flash and boot the result

```bash
xz -dc deploy/ara-kiosk-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Or use Raspberry Pi Imager → "Use custom image" → select the `.img.xz`.

---

## Post-flash verification checklist

After first boot (give it ~3 minutes for Docker pull), SSH in (`ssh pi@kiosk.local`) and run:

```bash
# 1. reSpeaker XVF3800 detected
lsusb | grep -i 'xmos\|xvf'

# 2. PipeWire sees it as default sink AND source
wpctl status | grep -i respeaker
# Should show * next to it for both Sinks and Sources

# 3. Kiosk running on tty1
ps -ef | grep -E 'cage|chromium' | grep -v grep

# 4. HDMI active (and HDMI audio NOT present as a sink)
wpctl status | grep -i hdmi
# Should be empty or show HDMI as inactive

# 5. LVA container running
docker ps | grep lva

# 6. LVA listening on ESPHome port
ss -tlnp | grep 6053

# 7. mDNS announcement (HA picks this up automatically)
avahi-browse -art 2>&1 | grep -i "$(hostname)"

# 8. picompose service succeeded
systemctl status picompose --no-pager
journalctl -u picompose --no-pager | tail -30
```

In Home Assistant: **Settings → Devices & Services**. A new ESPHome discovery should appear for `kiosk` (or whatever `LVA_NAME` you set). Click **Add**.

Test voice: say "**Okay Nabu**, what time is it?". You should see the LED ring respond (if `xvf3800-led.service` was enabled), the kiosk speakers play the response, and the HA logbook show the interaction.

---

## Per-device customization (FAT32 partition)

After flashing, before first boot — or any time with the SD card mounted in any laptop — drop or edit these files on the FAT32 boot partition:

| File | Purpose | Required? |
|---|---|---|
| `/boot/firmware/userconf.txt` | username:bcrypt-hash (Imager populates this) | Imager-managed |
| `/boot/firmware/wpa_supplicant.conf` | Wi-Fi creds (Imager populates this) | Imager-managed |
| `/boot/firmware/kiosk.conf` | Kiosk URL + Chromium flags | Optional |
| `/boot/firmware/compose/lva/.env` | LVA name + wake word | Optional |

For 5–10 kiosks, the per-device deltas are:

```bash
# Per device, on a laptop with the SD card mounted:
HOSTNAME=kiosk-livingroom

cat > /Volumes/bootfs/kiosk.conf <<EOF
KIOSK_URL=https://192.168.1.210:8123/lovelace/${HOSTNAME}
EOF

cat > /Volumes/bootfs/compose/lva/.env <<EOF
LVA_NAME=${HOSTNAME}
LVA_WAKE_MODEL=okay_nabu
EOF
```

Hostname/SSH key/Wi-Fi go through Imager's customization wizard.

---

## Troubleshooting reference

### Kiosk shows blank screen / cert error

The default cert error path is silenced by `--ignore-certificate-errors --test-type` in the launcher. If you still see issues:

```bash
# On the kiosk:
ssh pi@kiosk.local
journalctl --user -u cage 2>/dev/null
cat /home/pi/.config/kiosk/start-kiosk.sh
# Test the URL manually:
curl -kv "$(grep KIOSK_URL /boot/firmware/kiosk.conf | cut -d= -f2)"
```

If the cert is the actual problem, switch to the Nabu Casa URL by editing `/boot/firmware/kiosk.conf` and rebooting.

### LVA not auto-discovered by HA

```bash
# Confirm LVA is actually running:
docker logs lva | tail -50

# Confirm mDNS is announcing:
avahi-browse -art | grep -i esphome

# Confirm port 6053 is open:
ss -tlnp | grep 6053
```

If LVA is running but HA doesn't see it: HA's mDNS discovery may need a kick. Restart HA's "ESPHome" integration, or manually add the satellite by IP.

### Microphone not detected

```bash
# Is XVF3800 enumerating?
lsusb -v 2>/dev/null | grep -A2 -i xmos

# Is PipeWire seeing it?
wpctl status

# What sample rates does it advertise?
arecord -D plughw:CARD=ARRAY -r 16000 -c 2 -f S32_LE -d 3 /tmp/test.wav
aplay /tmp/test.wav
```

If `lsusb` doesn't show it, you may need to flash USB firmware (the device may have shipped with I2S firmware). See the Seeed wiki:

```bash
sudo dfu-util -l
sudo dfu-util -R -e -a 1 -D /path/to/respeaker_xvf3800_usb_dfu_firmware_v2.0.x.bin
```

### TTS plays through HDMI, not 3.5mm

The `dtoverlay=vc4-kms-v3d,noaudio` line in `/boot/firmware/config.txt` should prevent this. Confirm:

```bash
grep -E 'vc4-kms-v3d' /boot/firmware/config.txt
# Must show ',noaudio' suffix
```

If it doesn't, edit and reboot. The PipeWire rule pinning the reSpeaker as priority 2000 also helps but isn't sufficient on its own when HDMI audio is exposed.

### picompose stuck waiting for PulseAudio socket

The `picompose` script waits up to 60 seconds for `/run/user/1000/pulse/native`. If it consistently times out:

```bash
# Is lingering enabled for pi?
loginctl show-user pi | grep Linger

# Is the user systemd running?
systemctl --user --machine=pi@.host status pipewire-pulse
```

If lingering is off, run `sudo loginctl enable-linger pi` and reboot.

---

## Future enhancements

These are explicitly **out of scope** for this initial build but worth noting for future work:

1. **LED feedback wired to LVA wake-word state.** The `xvf3800-led.service` stub is in place. To activate, write a small Python daemon that subscribes to LVA's ESPHome API events (wake detected, listening, processing, speaking) and calls `xvf_host SET_LED_RING_*` accordingly. Easiest path: a sidecar container in the LVA compose stack.
2. **Direction-of-arrival as an HA sensor.** `xvf_host` can report DOA angle. Pipe this to MQTT and ingest in HA as a sensor; useful for room-aware automations.
3. **Tailscale baked in.** Add a `06-stage-tailscale/` that installs Tailscale and a first-boot service that runs `tailscale up --authkey=$(cat /boot/firmware/tailscale.authkey)`. Auth key dropped per-device on FAT32.
4. **Read-only root.** Once the image is stable, switch to overlayfs root for resilience to power loss.
5. **PR the XVF3800 stage back to upstream PiCompose.** After enough soak time, open a PR adding `02-stage-audiodriver-xvf3800/` to `florian-asche/PiCompose`. Several PiCompose users have requested it.
6. **Self-signed CA into system trust.** Drop the user's HA root CA into `/usr/local/share/ca-certificates/` in a stage script and run `update-ca-certificates`. Lets us remove `--ignore-certificate-errors`.
7. **Ansible-pull for runtime drift.** Once a fleet exists, add a systemd timer that runs `ansible-pull` against a Gitea repo on `chronos` for non-image-level config (Chromium flags, dashboard URLs, LVA wake words).

---

## Implementation order summary

For Claude Code: execute steps in this order, committing each as a logical unit. Stop and report on any failure rather than working around upstream layout drift.

1. Pre-flight verification (Step 0 implicit — the verification block)
2. Step 1: clean up unused stages, commit
3. Step 8: rename `04-stage-finish` → `05-stage-finish`, commit (do this before adding new stage 04 to avoid name collision)
4. Step 2: write `config`, commit
5. Step 3: write `stage-list`, commit
6. Step 4: audit and patch `01-stage-picompose`, commit
7. Step 5: create `02-stage-audiodriver-xvf3800`, commit
8. Step 6: rework `03-stage-linux-voice-assistant`, commit
9. Step 7: create `04-stage-kiosk`, commit
10. Step 9: update GitHub Actions workflow (disabled), commit
11. Step 10: rewrite `README.md`, commit
12. Add `scripts/build-local.sh`, commit
13. Final: report tree structure with `tree -L 3 -I '.git|.pi-gen-work'` and a summary diff against upstream

After Claude Code finishes, the user runs `./scripts/build-local.sh` to validate.

#!/bin/bash -e
#
# 02-stage-audiodriver-xvf3800 / 01-xvf3800
#
# Configures the host for the Seeed reSpeaker XVF3800 USB-4MIC ARRAY (no-XIAO
# variant). PipeWire / WirePlumber / pipewire-pulse / lingering are already
# installed in stage 01 (01-stage-picompose/03-install-pipewire-audio); this
# stage only adds:
#
#   - udev rules so the pi user can talk to the device without sudo
#   - a WirePlumber rule pinning the reSpeaker as the highest-priority
#     sink/source
#   - an XVF3800-tuned PipeWire clock config that overrides the stage-01
#     default of 16 kHz with 48 kHz native + 16 kHz allowed (lets capture
#     run at the device rate when only the reSpeaker is active)
#   - a config.txt patch disabling HDMI audio at the device-tree level so
#     the reSpeaker is the only sink and the on-board AEC reference stays
#     correct
#   - an `xvf_host` install for LED ring / DOA / DSP control (system-wide
#     pip with --break-system-packages, intentional for this purpose-built
#     image)
#   - a stub xvf3800-led.service (NOT enabled by default — wiring it to
#     LVA wake-word state is a documented follow-up)

USER_HOME="/home/${FIRST_USER_NAME}"
USER_UID="1000"

# udev rules: DFU-mode VID and XMOS production VID
install -v -m 644 files/etc/udev/rules.d/99-xvf3800.rules \
    "${ROOTFS_DIR}/etc/udev/rules.d/99-xvf3800.rules"

# WirePlumber rule pinning the reSpeaker as default sink + source.
# Stage 01 already created /etc/wireplumber/wireplumber.conf.d/.
install -v -m 644 files/etc/wireplumber/wireplumber.conf.d/51-respeaker.conf \
    "${ROOTFS_DIR}/etc/wireplumber/wireplumber.conf.d/51-respeaker.conf"

# PipeWire clock override. Stage 01 sets default.clock.rate=16000 (good for
# voice satellites), but with HDMI gone the reSpeaker drives playback too,
# so we want 48 kHz native and 16 kHz allowed.
install -v -m 644 files/etc/pipewire.conf.d/20-xvf3800-clock.conf \
    "${ROOTFS_DIR}/etc/pipewire.conf.d/20-xvf3800-clock.conf"

# Disable HDMI audio in the device tree (matches both [pi5] and global
# vc4-kms-v3d lines; no-op if already set with ,noaudio).
sed -i -E 's|^(dtoverlay=vc4-kms-v3d)(,[^[:space:]]+)?[[:space:]]*$|\1,noaudio|' \
    "${ROOTFS_DIR}/boot/firmware/config.txt"

# xvf_host: install Seeed's XMOS USB control tool for LED ring / DOA / DSP
# tuning. Bookworm enforces PEP 668 on system Python; --break-system-packages
# is acceptable for a purpose-built image where we own all Python state.
on_chroot << 'CHROOT_EOF'
set -e
pip3 install --break-system-packages --no-cache-dir xmos-xvf-host \
    || pip3 install --break-system-packages --no-cache-dir \
        'git+https://github.com/respeaker/reSpeaker_XVF3800_USB_4MIC_ARRAY.git#subdirectory=xvf_host_app' \
    || echo "WARN: xvf_host install failed — LED control will be unavailable until installed manually"
CHROOT_EOF

# Stub LED daemon (disabled by default; activate after validating xvf_host
# verbs against the actual hardware firmware version).
install -v -m 755 files/usr/local/bin/xvf3800-led \
    "${ROOTFS_DIR}/usr/local/bin/xvf3800-led"
install -v -m 644 files/etc/systemd/system/xvf3800-led.service \
    "${ROOTFS_DIR}/etc/systemd/system/xvf3800-led.service"

# Group memberships. `audio` and `video` are Bookworm defaults for `pi`,
# but `plugdev` is needed for the udev rules above and `render` is needed
# for VAAPI in Chromium (kiosk stage uses --enable-features=VaapiVideoDecoder).
on_chroot << CHROOT_EOF
usermod -aG audio,video,render,plugdev ${FIRST_USER_NAME}
# Lingering already enabled in stage 01; idempotent re-touch is a no-op.
loginctl enable-linger ${FIRST_USER_NAME}
CHROOT_EOF

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
#   - the upstream `xvf_host` suite for LED ring / DOA / DSP control,
#     downloaded at build time from Seeed's reSpeaker_XVF3800_USB_4MIC_ARRAY
#     repo (host_control/rpi_64bit/) and installed under
#     /opt/respeaker-xvf3800/ with PATH wrappers
#   - xvf3800-led.service that sets a steady idle color on boot

# Pinned to a specific commit for build reproducibility. Bump as needed
# when Seeed publishes new firmware/control binaries.
XVF_REPO_SHA="2ce5fa60620642815b8bb056002ba9e21f4c6686"
XVF_BASE_URL="https://raw.githubusercontent.com/respeaker/reSpeaker_XVF3800_USB_4MIC_ARRAY/${XVF_REPO_SHA}/host_control/rpi_64bit"
XVF_FILES=(
    xvf_host
    xvf_i2c_dfu
    libcommand_map.so
    libdevice_usb.so
    libdevice_i2c.so
    dfu_cmds.yaml
    transport_config.yaml
)

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

# Download the xvf_host suite. These are pre-built arm64 binaries + shared
# libraries from Seeed; there's no PyPI package and the repo is a git mirror
# of opaque XMOS tooling, so the only sensible install path is to fetch the
# specific files we need from the pinned commit.
XVF_DEST="${ROOTFS_DIR}/opt/respeaker-xvf3800"
install -v -d -m 755 "${XVF_DEST}"

xvf_install_ok=true
for f in "${XVF_FILES[@]}"; do
    if ! curl -fsSL --retry 3 --retry-delay 2 \
            -o "${XVF_DEST}/${f}" "${XVF_BASE_URL}/${f}"; then
        echo "WARN: failed to fetch ${f} from ${XVF_BASE_URL}"
        xvf_install_ok=false
        break
    fi
done

if "${xvf_install_ok}"; then
    chmod 0755 "${XVF_DEST}/xvf_host" "${XVF_DEST}/xvf_i2c_dfu"
    chmod 0644 "${XVF_DEST}"/*.so "${XVF_DEST}"/*.yaml
    echo "==> xvf_host suite installed to /opt/respeaker-xvf3800/"
else
    echo "WARN: xvf_host install incomplete; LED + DSP control will be unavailable"
    rm -rf "${XVF_DEST}"
fi

# PATH wrappers — set LD_LIBRARY_PATH and cd into the install dir so the
# binary finds its .so files and the YAML config files relative to CWD.
install -v -m 755 files/usr/local/bin/xvf_host \
    "${ROOTFS_DIR}/usr/local/bin/xvf_host"
install -v -m 755 files/usr/local/bin/xvf_i2c_dfu \
    "${ROOTFS_DIR}/usr/local/bin/xvf_i2c_dfu"

# LED daemon — installs a steady idle color on boot and exits. Enabled by
# default now that we have real verbs.
install -v -m 755 files/usr/local/bin/xvf3800-led \
    "${ROOTFS_DIR}/usr/local/bin/xvf3800-led"
install -v -m 644 files/etc/systemd/system/xvf3800-led.service \
    "${ROOTFS_DIR}/etc/systemd/system/xvf3800-led.service"

# LED bridge — tails `docker logs -f lva` and translates LVA voice
# pipeline state (listening / thinking / speaking / idle) into
# xvf_host LED commands. Requires LVA's ENABLE_DEBUG="1" so the
# satellite logs every "Voice event:" transition (set in our
# /compose/lva/.env defaults).
install -v -m 755 files/usr/local/bin/xvf3800-led-bridge \
    "${ROOTFS_DIR}/usr/local/bin/xvf3800-led-bridge"
install -v -m 644 files/etc/systemd/system/xvf3800-led-bridge.service \
    "${ROOTFS_DIR}/etc/systemd/system/xvf3800-led-bridge.service"

on_chroot << 'CHROOT_EOF'
systemctl daemon-reload
systemctl enable xvf3800-led.service
systemctl enable xvf3800-led-bridge.service
CHROOT_EOF

# Group memberships. `audio` and `video` are RPi-OS defaults for `pi`,
# but `plugdev` is needed for the udev rules above and `render` is needed
# for VAAPI in Chromium (kiosk stage uses --enable-features=VaapiVideoDecoder).
#
# Note: lingering for `pi` is already enabled by 01-stage-picompose/
# 03-install-pipewire-audio/02-run.sh, which uses the chroot-safe
# `touch /var/lib/systemd/linger/pi` pattern. Don't call
# `loginctl enable-linger` here — it requires a running session bus
# and fails the build inside the pi-gen chroot ("System has not been
# booted with systemd as init system (PID 1)").
on_chroot << CHROOT_EOF
usermod -aG audio,video,render,plugdev ${FIRST_USER_NAME}
CHROOT_EOF

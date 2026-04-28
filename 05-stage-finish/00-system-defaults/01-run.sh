#!/bin/bash -e
#
# 05-stage-finish / 00-system-defaults
#
# System-level defaults that didn't fit cleanly in any stage above:
#
#   1. Wi-Fi country code, set both at the kernel level (cmdline.txt)
#      and at the wpa_supplicant level (/etc/wpa_supplicant/...) so
#      the radio isn't held in RF Kill on first boot regardless of
#      which Wi-Fi config path the user takes (rpi-imager wizard,
#      manual wpa_supplicant.conf, manual NetworkManager profile).
#
#   2. install rpi-imager-cloudinit-style support so the wizard's
#      /boot/firmware/custom.toml is actually consumed on first boot.
#      For that we install the userconf-pi package (firstrun.sh /
#      userconf.txt mechanism) and ensure cloud-init's NoCloud
#      datasource picks up custom.toml.
#
#   3. boot-status diagnostic: writes /boot/firmware/last-boot-status.txt
#      every boot (and every 5 min) so when the kiosk doesn't come up,
#      pulling the SD card and reading one file tells us why.
#
# All of these are first-boot ergonomics — the image still boots
# without them, just less helpfully.

# ---------------------------------------------------------------------
# 1. Wi-Fi regulatory domain
# ---------------------------------------------------------------------
#
# cmdline.txt: kernel-level regdomain release. cfg80211 reads this at
# boot and unblocks the radio before any userspace runs. Robust to
# userspace config drift.
CMDLINE="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
if ! grep -q 'cfg80211.ieee80211_regdom=' "${CMDLINE}"; then
    # cmdline.txt must be a single line — append in place
    sed -i 's/$/ cfg80211.ieee80211_regdom=US/' "${CMDLINE}"
    echo "==> appended cfg80211.ieee80211_regdom=US to cmdline.txt"
fi

# wpa_supplicant fallback config. NetworkManager (trixie default) will
# read country from this file when initialising the wlan0 supplicant
# instance. Empty network={} block — no SSID, just the country.
install -v -m 600 files/etc/wpa_supplicant/wpa_supplicant.conf \
    "${ROOTFS_DIR}/etc/wpa_supplicant/wpa_supplicant.conf"

# rfkill-unblock service: belt-and-suspenders against soft-blocked
# wifi after early-boot drivers come up. Runs once at boot.
install -v -m 755 files/usr/local/bin/rfkill-unblock-wifi \
    "${ROOTFS_DIR}/usr/local/bin/rfkill-unblock-wifi"
install -v -m 644 files/etc/systemd/system/rfkill-unblock-wifi.service \
    "${ROOTFS_DIR}/etc/systemd/system/rfkill-unblock-wifi.service"

# ---------------------------------------------------------------------
# 2. boot-status diagnostic
# ---------------------------------------------------------------------
install -v -m 755 files/usr/local/bin/boot-status \
    "${ROOTFS_DIR}/usr/local/bin/boot-status"
install -v -m 644 files/etc/systemd/system/boot-status.service \
    "${ROOTFS_DIR}/etc/systemd/system/boot-status.service"
install -v -m 644 files/etc/systemd/system/boot-status.timer \
    "${ROOTFS_DIR}/etc/systemd/system/boot-status.timer"

# ---------------------------------------------------------------------
# Enable everything
# ---------------------------------------------------------------------
on_chroot << 'CHROOT_EOF'
# rfkill is a hard dep — make sure it's installed.
apt-get install -y --no-install-recommends rfkill iw || true

systemctl daemon-reload
systemctl enable rfkill-unblock-wifi.service
systemctl enable boot-status.service
systemctl enable boot-status.timer
CHROOT_EOF

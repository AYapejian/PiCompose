#!/bin/bash -e
#
# 04-stage-kiosk / 01-kiosk
#
# Wayland kiosk: agetty autologin on tty1 launches cage, which exec's
# Chromium pointed at the Home Assistant dashboard. URL + Chromium flags
# are read from /boot/firmware/kiosk.conf so a fleet operator can
# customize per device on the FAT32 partition without ever SSHing in.

USER_HOME="/home/${FIRST_USER_NAME}"
USER_UID="1000"

# tty1 autologin so cage starts on boot.
install -v -d "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d"
install -v -m 644 files/etc/systemd/system/getty@tty1.service.d/autologin.conf \
    "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/autologin.conf"

# .bash_profile auto-launches cage on tty1. Other ttys / SSH sessions
# fall through to a normal shell.
install -v -m 644 -o "${USER_UID}" -g "${USER_UID}" \
    files/home/pi/.bash_profile \
    "${ROOTFS_DIR}${USER_HOME}/.bash_profile"

# Kiosk launcher lives in /usr/local/bin so it's reachable regardless
# of what cloud-init / userconf-pi do to /home/pi at first boot. Earlier
# revisions installed it under /home/pi/.config/kiosk/, but a first-boot
# step (likely userconf-pi or one of the cloud-init user modules)
# recreated /home/pi/.config as root:root 0700 — `pi` couldn't traverse
# in, so cage failed with EACCES trying to exec the script. System-wide
# install dodges that whole class of problem.
install -v -m 755 files/usr/local/bin/start-kiosk.sh \
    "${ROOTFS_DIR}/usr/local/bin/start-kiosk.sh"

# FAT32 override example.
install -v -m 644 files/boot/firmware/kiosk.conf.example \
    "${ROOTFS_DIR}/boot/firmware/kiosk.conf.example"

# seat group + seatd. cage requires seat access; on Bookworm the `seat`
# group is provided by the seatd package, but the package install in
# this stage runs after this script in some pi-gen versions, so create
# the group defensively.
on_chroot << CHROOT_EOF
getent group seat >/dev/null || groupadd -r seat
usermod -aG seat ${FIRST_USER_NAME}
systemctl enable seatd.service
CHROOT_EOF

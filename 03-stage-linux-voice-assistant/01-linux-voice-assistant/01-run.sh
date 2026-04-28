#!/bin/bash -e
#
# 03-stage-linux-voice-assistant / 01-linux-voice-assistant
#
# Drops the LVA compose project into /compose/lva so picompose deploys
# it on first boot, and installs an lva-env-sync.service that lets the
# operator pin per-device LVA env overrides on the FAT32 partition.

# /compose is created by stage 01 (01-stage-picompose/02-picompose).
mkdir -p "${ROOTFS_DIR}/compose/lva"

install -v -m 644 files/lva/docker-compose.yml \
    "${ROOTFS_DIR}/compose/lva/docker-compose.yml"
install -v -m 644 files/lva/picompose.conf \
    "${ROOTFS_DIR}/compose/lva/picompose.conf"
install -v -m 644 files/lva/.env \
    "${ROOTFS_DIR}/compose/lva/.env"

# FAT32 override example. Operators copy this to /boot/firmware/lva.env
# (no .example suffix) and edit before first boot.
install -v -m 644 files/boot/firmware/lva.env.example \
    "${ROOTFS_DIR}/boot/firmware/lva.env.example"

# Hot-sync service: /boot/firmware/lva.env -> /compose/lva/.env, runs
# before picompose.service. Enabled unconditionally; it no-ops when
# the FAT32 file is absent.
install -v -m 755 files/usr/local/bin/lva-env-sync \
    "${ROOTFS_DIR}/usr/local/bin/lva-env-sync"
install -v -m 644 files/etc/systemd/system/lva-env-sync.service \
    "${ROOTFS_DIR}/etc/systemd/system/lva-env-sync.service"

on_chroot << 'CHROOT_EOF'
systemctl daemon-reload
systemctl enable lva-env-sync.service
CHROOT_EOF

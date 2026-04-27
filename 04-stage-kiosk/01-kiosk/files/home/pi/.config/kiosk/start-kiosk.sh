#!/usr/bin/env bash
# start-kiosk.sh — fired by cage on tty1 to launch a fullscreen
# Chromium pointed at Home Assistant.
#
# Defaults can be overridden by dropping /boot/firmware/kiosk.conf on
# the FAT32 partition (see kiosk.conf.example). KIOSK_URL and
# EXTRA_FLAGS are the two knobs.

set -euo pipefail

CONF=/boot/firmware/kiosk.conf
KIOSK_URL="https://192.168.1.210:8123"
EXTRA_FLAGS=""

# shellcheck source=/dev/null
[ -f "$CONF" ] && source "$CONF"

# Parse host:port out of the URL so we can wait for HA to be reachable
# before launching Chromium. Avoids the user staring at "site can't be
# reached" if the kiosk boots faster than the HA host.
host="${KIOSK_URL#https://}"
host="${host#http://}"
host="${host%%/*}"
port="${host##*:}"
host="${host%%:*}"
case "$KIOSK_URL" in
    https://*) port="${port:-443}" ;;
    http://*)  port="${port:-80}"  ;;
    *)         port="${port:-443}" ;;
esac

echo "kiosk: waiting for ${host}:${port}"
until nc -z "$host" "$port" 2>/dev/null; do
    sleep 1
done
echo "kiosk: ${host}:${port} reachable, launching Chromium"

# --ignore-certificate-errors covers HA's self-signed cert on the LAN
# default. --test-type silences the warning chip Chromium otherwise
# pins to the top of the kiosk window.
# shellcheck disable=SC2086
exec chromium \
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

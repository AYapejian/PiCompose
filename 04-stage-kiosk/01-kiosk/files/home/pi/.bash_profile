# Auto-start the kiosk on tty1 only. Other ttys and SSH sessions get
# a normal shell so they can still be used for diagnostics.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec cage -s -- "$HOME/.config/kiosk/start-kiosk.sh"
fi

# Standard interactive shell setup
if [ -f "$HOME/.bashrc" ]; then
    # shellcheck source=/dev/null
    . "$HOME/.bashrc"
fi

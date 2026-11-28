#!/bin/sh
# Grant one local account access to the current uinput node (until reboot).
set -eu
case "${1:-}" in
    ''|*[!0-9]*) echo 'Usage: enable-gamepad.sh NUMERIC_UID' >&2; exit 1 ;;
esac
modprobe uinput
setfacl -m "u:$1:rw" /dev/uinput

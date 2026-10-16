#!/usr/bin/env bash
# Spike B: provision, sign and install the runner on the iPhone with xtool.
# The device link is Apple's Windows device service (Apple Devices app) reached
# over WSL mirrored networking, not usbipd: usbipd corrupts large USB transfers
# (usbmuxd: "message was too large (65536 bytes, max = 65535)").
# stdin is closed, so xtool cannot be told "yes" to revoking certificates: it stops instead.
# The raw log stays in scratch; print it with showlog.sh (device identifiers redacted).
# Usage: install.sh [runner-dir] [log-file]
set -uo pipefail
export USBMUXD_SOCKET_ADDRESS=${USBMUXD_SOCKET_ADDRESS:-127.0.0.1:27015}
cd "${1:-$HOME/spikes/spike-b/runner}"
LOG=${2:-$HOME/spikes/spike-b/install.log}
T0=$(date +%s)
xtool install --usb xtool/CounterRunner.app </dev/null >"$LOG" 2>&1
rc=$?
echo "install_exit=$rc seconds=$(( $(date +%s) - T0 ))" >>"$LOG"
exit "$rc"

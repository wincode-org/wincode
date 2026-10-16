#!/usr/bin/env bash
# Spike B: capture the iPhone's system log while the app is launched by hand.
# Raw log stays in scratch (it can contain device names); view it with showlog-device.sh.
# Usage: logs.sh [seconds] [log-file]
set -uo pipefail
export USBMUXD_SOCKET_ADDRESS=${USBMUXD_SOCKET_ADDRESS:-127.0.0.1:27015}
SECS=${1:-600}
LOG=${2:-$HOME/spikes/spike-b/device.log}
timeout "$SECS" idevicesyslog --no-colors >"$LOG" 2>&1 || timeout "$SECS" idevicesyslog >"$LOG" 2>&1

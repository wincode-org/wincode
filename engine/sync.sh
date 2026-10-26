#!/usr/bin/env bash
# Fetch the standalone Dart SDK at the dart_revision that a Flutter release pins (ADR-0004).
# Sources: chromium.googlesource.com (depot_tools), dart.googlesource.com, and the CIPD packages Dart's DEPS names.
#
# Usage: engine/sync.sh <Flutter SDK folder>
#   WINCODE_HOME   where winCode keeps its build folders and tools (default: ~/.wincode)
#   DEPOT_TOOLS    an existing depot_tools checkout to reuse (default: one under WINCODE_HOME)
set -euo pipefail

FLUTTER=$(cd "${1:?usage: sync.sh <Flutter SDK folder>}" && pwd)
HOME_DIR=${WINCODE_HOME:-$HOME/.wincode}
ENGINE=$(tr -d '[:space:]' < "$FLUTTER/bin/internal/engine.version")
DREV=$(sed -n "s/^ *'dart_revision': '\([0-9a-f]\{40\}\)'.*/\1/p" "$FLUTTER/DEPS" | head -1)
[ -n "$DREV" ] || { echo "no dart_revision in $FLUTTER/DEPS" >&2; exit 1; }

WORK=$HOME_DIR/engine-build/${ENGINE:0:10}
DEPOT=${DEPOT_TOOLS:-$HOME_DIR/engine-build/depot_tools}
echo "Flutter engine $ENGINE pins Dart $DREV"
df -h "$HOME" | tail -1

[ -d "$DEPOT" ] || git clone -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT"
export PATH="$DEPOT:$PATH" DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0

mkdir -p "$WORK/dart-sdk" && cd "$WORK/dart-sdk"
cat > .gclient <<G
solutions = [{
  "name": "sdk",
  "url": "https://dart.googlesource.com/sdk.git@$DREV",
  "deps_file": "DEPS",
  "managed": False,
  "custom_deps": {},
  "custom_vars": {"download_reclient": False},
}]
G
T0=$(date +%s)
nice -n 10 gclient sync --no-history --shallow -r "sdk@$DREV" -j 8
echo "sync_seconds=$(( $(date +%s) - T0 ))"
du -sh "$WORK/dart-sdk" "$DEPOT"
df -h "$HOME" | tail -1

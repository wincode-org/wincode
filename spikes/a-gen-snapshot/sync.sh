#!/usr/bin/env bash
# Spike A1: fetch the standalone Dart SDK at the dart_revision pinned by Flutter 3.47.7.
# Sources: chromium.googlesource.com (depot_tools), dart.googlesource.com, CIPD.
set -euo pipefail
SPIKE=${SPIKE:-$HOME/spikes/spike-a}
DREV=04bcd1036cdc799ac6564988f159ee454d42c822   # dart_revision in flutter 3.47.7 DEPS (Dart 3.13.5)

df -h "$HOME" | tail -1
[ -d "$SPIKE/depot_tools" ] || git clone -q --depth 1 \
  https://chromium.googlesource.com/chromium/tools/depot_tools.git "$SPIKE/depot_tools"
export PATH="$SPIKE/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0

mkdir -p "$SPIKE/dart-sdk" && cd "$SPIKE/dart-sdk"
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
du -sh "$SPIKE/dart-sdk" "$SPIKE/depot_tools"
df -h "$HOME" | tail -1

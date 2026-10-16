#!/usr/bin/env bash
# Spike B: stage the runner package and the prebuilt Flutter.xcframework in a scratch directory.
# Usage: stage.sh [out-dir]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SPIKE_A=${SPIKE_A:-$HOME/spikes/spike-a}
OUT=${1:-$HOME/spikes/spike-b/runner}
FLUTTER_XCF=${FLUTTER_XCF:-$SPIKE_A/flutter/bin/cache/artifacts/engine/ios-release/Flutter.xcframework}

rm -rf "$OUT" && mkdir -p "$OUT"
cp -r "$HERE/runner/." "$OUT/"
cp -r "$FLUTTER_XCF" "$OUT/Flutter.xcframework"   # prebuilt engine, unmodified
echo "staged $OUT"

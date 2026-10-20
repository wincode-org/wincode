#!/usr/bin/env bash
# Spike E: the inputs spikes A and B used, rebuilt after a lost WSL disk:
# Flutter 3.47.7 with its iOS engine artifacts, and the Linux-built iOS gen_snapshot.
# Skips what already exists. Needs tools/setup-wsl-toolchain.sh first (Swift, xtool, Darwin SDK).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SPIKE=${SPIKE:-$HOME/spikes/spike-a}
FLUTTER_ROOT=$SPIKE/flutter
GS=$SPIKE/dart-sdk/sdk/out/ProductIOSARM64Linux/clang_x64/gen_snapshot
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true

mkdir -p "$SPIKE"
[ -d "$FLUTTER_ROOT" ] || git clone -q --depth 1 --branch 3.47.7 https://github.com/flutter/flutter.git "$FLUTTER_ROOT"
"$FLUTTER_ROOT/bin/flutter" --version
"$FLUTTER_ROOT/bin/flutter" precache --ios   # ios, ios-profile and ios-release engine artifacts

[ -x "$GS" ] || { bash "$HERE/../a-gen-snapshot/sync.sh"; bash "$HERE/../a-gen-snapshot/build.sh"; }
"$GS" --version

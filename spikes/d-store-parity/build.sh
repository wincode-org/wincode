#!/usr/bin/env bash
# Spike D: bring a Windows-built bundle closer to the Xcode-built one, one fix at a time:
#   a  SDK stamp: link with -platform_version ios <minos> <SDK version> (the linker's own flag)
#   b  runner hygiene: release build, and only /usr/lib/swift and @executable_path/Frameworks as rpaths
#   c  Info.plist: the app's own ios/Runner/Info.plist merged in, plus the DT keys from the SDK's files
#   d  assets: no .last_build_id, shaders compiled for iOS
# Starts from spike E's output for the app (App.framework, native-asset frameworks). Keeps a copy of the
# .app after each step (0-baseline, a-sdk, b-runner, c-plist, d-assets) and, given the Xcode-built
# reference, a tools/ipa-diff report for each.
# Usage: build.sh <app-dir> <spike-e-out-dir> <out-dir> [reference .app or artifact folder]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
APP=$(cd "$1" && pwd)
E=$(cd "$2" && pwd)
OUT=$3
REF=${4:-}
SPIKE_A=${SPIKE_A:-$HOME/spikes/spike-a}
SDK=$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
FIX="python3 $HERE/bundle_fix.py"
rm -rf "$OUT" && mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd)

SDK_VERSION=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['Version'])" "$SDK/SDKSettings.json")
MINOS=$(sed -n 's/.*\.iOS(\.v\([0-9]*\)).*/\1.0/p' "$REPO/spikes/b-device/runner/Package.swift")

runner() {  # runner() <debug|release> <link flags or empty>: the spike B runner with App.framework embedded
  RUNNER=$OUT/runner-$1
  SPIKE_A="$SPIKE_A" bash "$REPO/spikes/b-device/stage.sh" "$RUNNER" >/dev/null
  if [ -n "$2" ]; then
    perl -0pi -e "s/dependencies: \[\"Flutter\"\]/dependencies: [\"Flutter\"],\n            linkerSettings: [.unsafeFlags([$2])]/" "$RUNNER/Package.swift"
  fi
  (cd "$RUNNER" && xtool dev build -c "$1" >build.log 2>&1) || { tail -20 "$RUNNER/build.log"; exit 1; }
  BUNDLE=$RUNNER/xtool/CounterRunner.app
  cp -r "$E/app-framework/App.framework" "$BUNDLE/Frameworks/"
  for fw in "$E"/frameworks/*.framework; do [ -e "$fw" ] && cp -r "$fw" "$BUNDLE/Frameworks/"; done
  return 0
}
snap() { cp -r "$BUNDLE" "$OUT/$1.app"; echo "== $1"; }

BUNDLE=$E/runner/xtool/CounterRunner.app; snap 0-baseline

PLATFORM_FLAGS="\"-Xlinker\", \"-platform_version\", \"-Xlinker\", \"ios\", \"-Xlinker\", \"$MINOS\", \"-Xlinker\", \"$SDK_VERSION\""
runner debug "$PLATFORM_FLAGS"; snap a-sdk

runner release "$PLATFORM_FLAGS"
$FIX rpaths "$BUNDLE/CounterRunner" /usr/lib/swift @executable_path/Frameworks
snap b-runner

$FIX plist "$BUNDLE" "$APP/ios/Runner/Info.plist" "$SDK" "$APP/pubspec.yaml"; snap c-plist

rm -f "$BUNDLE/Frameworks/App.framework/flutter_assets/.last_build_id"
$FIX shaders "$BUNDLE" "$SPIKE_A/flutter"; snap d-assets

NAME=$(basename "$APP")
(cd "$OUT" && rm -rf Payload && mkdir Payload && cp -r d-assets.app Payload/CounterRunner.app && zip -qry "$NAME-unsigned.ipa" Payload && rm -rf Payload)

if [ -n "$REF" ]; then
  for s in 0-baseline a-sdk b-runner c-plist d-assets; do
    python3 "$REPO/tools/ipa-diff" "$OUT/$s.app" "$REF" >"$OUT/ipa-diff-$s.txt" || true
    printf '%-11s' "$s"
    awk '/^== /{if (s) printf "  %s %d", s, n; s=$2; n=0; next} s && /^  /&&!/^  --/&&!/no differences/{n++} END{printf "  %s %d\n", s, n}' "$OUT/ipa-diff-$s.txt"
  done
fi

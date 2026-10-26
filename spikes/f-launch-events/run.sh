#!/bin/bash
# Spike F, on a macOS runner: what does a storyboard launch give a plugin that a window made in code does not?
#
# A generic sample app (the stock `flutter create` app plus the plugin in plugin/) is built four times for the simulator:
#   A  the template as it is: Main.storyboard makes the window and the FlutterViewController
#   B  no storyboard; the window is made in code with FlutterViewController() (how winCode's runner did it)
#   C  no storyboard; the view controller is made the way a storyboard makes it: init(coder:) then awakeFromNib()
#   D  no storyboard; B, then Flutter's two fallback methods are called by selector
# The plugin writes every application and scene lifecycle event it receives to Documents/events.log. Each variant is run
# three ways (a launch; a cold launch from a URL; a launch and then a URL) and compare.py lines the logs up against A.
# No secrets, no signing, no client code. Needs flutter on PATH, Xcode, and the simulator runtimes of the runner image.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=${RUNNER_TEMP:-/tmp}
OUT=${OUT:-$TMP/launch-events-out}
WORK=$TMP/launch-events-work
PB=/usr/libexec/PlistBuddy
rm -rf "$OUT" "$WORK"
mkdir -p "$OUT/logs" "$OUT/apps" "$WORK"

{
  echo "xcode: $(xcodebuild -version | tr '\n' ' ')"
  echo "flutter: $(flutter --version 2>/dev/null | head -1)"
  echo "macOS: $(sw_vers -productVersion)"
} | tee "$OUT/environment.txt"

cd "$WORK" || exit 1
flutter create --org dev.wincode.spike --project-name launch_events --platforms ios app >/dev/null || exit 1
cd app || exit 1
mkdir -p plugins && cp -R "$HERE/plugin/launch_events_recorder" plugins/
flutter pub add launch_events_recorder --path plugins/launch_events_recorder >/dev/null || exit 1
flutter pub get >/dev/null || exit 1
BID=$(grep 'PRODUCT_BUNDLE_IDENTIFIER' ios/Runner.xcodeproj/project.pbxproj | grep -v RunnerTests | head -1 | sed -E 's/.*= *([^;]+);.*/\1/')
echo "bundle id: $BID" | tee -a "$OUT/environment.txt"

# The URL scheme for the URL scenarios; Flutter's own deep linking off, since nothing here handles a route.
P=ios/Runner/Info.plist
$PB -c "Add :CFBundleURLTypes array" $P
$PB -c "Add :CFBundleURLTypes:0 dict" $P
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLName string $BID" $P
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" $P
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string launchevents" $P
$PB -c "Add :FlutterDeepLinkingEnabled bool false" $P || $PB -c "Set :FlutterDeepLinkingEnabled false" $P
cp $P "$WORK/Info.base.plist"
cp ios/Runner/SceneDelegate.swift "$WORK/SceneDelegate.base.swift"

build_variant() {
  local v=$1
  cp "$WORK/Info.base.plist" $P
  cp "$WORK/SceneDelegate.base.swift" ios/Runner/SceneDelegate.swift
  if [ "$v" != A ]; then
    $PB -c "Delete :UIMainStoryboardFile" $P
    $PB -c "Delete :UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneStoryboardFile" $P
    # The launch screen's storyboard (UILaunchStoryboardName) stays, as it does in every variant; the main one must go.
    if plutil -p $P | grep -E 'UIMainStoryboardFile|UISceneStoryboardFile'; then
      echo "variant $v still names a main storyboard; skipped"
      return 1
    fi
    { cat "$HERE/variants/$v.swift"; printf '\nclass SceneDelegate: FlutterSceneDelegate {\n}\n'; } > ios/Runner/SceneDelegate.swift
  fi
  flutter build ios --simulator --debug >"$OUT/logs/build-$v.log" 2>&1 || { echo "build of $v failed"; tail -25 "$OUT/logs/build-$v.log"; return 1; }
  rm -rf "$OUT/apps/$v.app" && cp -R build/ios/iphonesimulator/Runner.app "$OUT/apps/$v.app"
}

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "SimRuntime.iOS-" not in runtime:
        continue
    version = tuple(int(x) for x in runtime.rsplit("iOS-", 1)[1].split("-"))
    for device in devices:
        if device["name"].startswith("iPhone") and device.get("isAvailable", True) and (best is None or version > best[0]):
            best = (version, device["udid"], device["name"])
print(best[1] if best else "")
')
[ -n "$UDID" ] || { echo "no iPhone simulator"; exit 1; }
echo "simulator: $(xcrun simctl list devices available | grep "$UDID" | sed -E 's/ \([0-9A-F-]{36}\).*//')" | tee -a "$OUT/environment.txt"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1

run_variant() {
  local v=$1 d="$OUT/logs/$1" c
  mkdir -p "$d"
  xcrun simctl uninstall "$UDID" "$BID" 2>/dev/null || true
  xcrun simctl install "$UDID" "$OUT/apps/$v.app" || return 1
  # A first launch makes the app's data container.
  xcrun simctl launch "$UDID" "$BID" >/dev/null; sleep 15; xcrun simctl terminate "$UDID" "$BID" 2>/dev/null; sleep 2
  c=$(xcrun simctl get_app_container "$UDID" "$BID" data) || return 1
  local log="$c/Documents/events.log"

  # 1. a normal launch
  rm -f "$log"
  xcrun simctl launch "$UDID" "$BID" >/dev/null; sleep 15
  xcrun simctl io "$UDID" screenshot "$d/cold.png" >/dev/null 2>&1
  cp "$log" "$d/cold.log" 2>/dev/null || echo "(no log)" > "$d/cold.nolog"
  xcrun simctl terminate "$UDID" "$BID" 2>/dev/null; sleep 2

  # 2. a cold launch from a URL
  rm -f "$log"
  xcrun simctl openurl "$UDID" "launchevents://cold?x=1"; sleep 15
  cp "$log" "$d/cold-url.log" 2>/dev/null || echo "(no log)" > "$d/cold-url.nolog"
  xcrun simctl terminate "$UDID" "$BID" 2>/dev/null; sleep 2

  # 3. a launch, then a URL while the app runs
  rm -f "$log"
  xcrun simctl launch "$UDID" "$BID" >/dev/null; sleep 15
  xcrun simctl openurl "$UDID" "launchevents://warm?y=2"; sleep 8
  xcrun simctl io "$UDID" screenshot "$d/warm-url.png" >/dev/null 2>&1
  cp "$log" "$d/warm-url.log" 2>/dev/null || echo "(no log)" > "$d/warm-url.nolog"
  xcrun simctl terminate "$UDID" "$BID" 2>/dev/null; sleep 2

  xcrun simctl spawn "$UDID" log show --last 15m --style compact --predicate 'process == "Runner"' 2>/dev/null | head -400 > "$d/syslog.txt" || true
  cp "$HOME"/Library/Logs/DiagnosticReports/Runner*.ips "$d/" 2>/dev/null || true
  rm -f "$HOME"/Library/Logs/DiagnosticReports/Runner*.ips
}

for v in A B C D; do
  echo "::group::variant $v"
  if build_variant "$v"; then run_variant "$v" || echo "variant $v did not run"; fi
  echo "::endgroup::"
done

python3 "$HERE/compare.py" "$OUT"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || cp "$OUT/summary.md" "$GITHUB_STEP_SUMMARY"
exit 0

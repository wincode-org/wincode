#!/usr/bin/env bash
# Spike B: unsigned build of the staged runner, then embed App.framework and check the bundle.
# Usage: build.sh [runner-dir]
set -euo pipefail
SPIKE_A=${SPIKE_A:-$HOME/spikes/spike-a}
APP_FW=${APP_FW:-$SPIKE_A/app-framework/App.framework}   # from spikes/a-gen-snapshot/make_app.sh
cd "${1:-$HOME/spikes/spike-b/runner}"

T0=$(date +%s)
xtool dev build
echo "build_seconds=$(( $(date +%s) - T0 ))"

APP=$PWD/xtool/CounterRunner.app
# Where the engine looks for it (FlutterDartProject.mm, FlutterNSBundleUtils.mm).
rm -rf "$APP/Frameworks/App.framework"
cp -r "$APP_FW" "$APP/Frameworks/App.framework"

echo "== bundle: $APP"
find "$APP" -maxdepth 3 -not -path "*/flutter_assets/*" -not -path "*/Headers/*" -not -path "*/Modules/*" | sed "s#$APP#CounterRunner.app#" | sort
file "$APP/CounterRunner"
echo "== runner load commands"
llvm-objdump --macho --dylibs-used "$APP/CounterRunner" | tail -n +2
llvm-objdump --macho --private-headers "$APP/CounterRunner" | grep -A2 "cmd LC_RPATH" | grep path
echo "== App.framework bundle ID: $(grep -A1 CFBundleIdentifier "$APP/Frameworks/App.framework/Info.plist" | tail -1 | tr -d '\t ')"

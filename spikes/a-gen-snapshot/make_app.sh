#!/usr/bin/env bash
# Spike A1: assemble App.framework for a Flutter app entirely on Linux, mirroring
# flutter_tools' iOS release steps at Flutter 3.47.7 (KernelSnapshot ->
# AotAssemblyRelease -> ReleaseIosApplicationBundle). Output is the input for spike B.
# Usage: make_app.sh [app-dir] [out-dir]
set -euo pipefail
SPIKE=${SPIKE:-$HOME/spikes/spike-a}
APP=$(cd "${1:-$SPIKE/counter}" && pwd)
OUT=${2:-$SPIKE/app-framework}
FLUTTER_ROOT=${FLUTTER_ROOT:-$SPIKE/flutter}
GS=${GS:-$SPIKE/dart-sdk/sdk/out/ProductIOSARM64Linux/clang_x64/gen_snapshot}
C=$FLUTTER_ROOT/bin/cache
DSYMUTIL=${DSYMUTIL:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/toolset/bin/dsymutil}
OBJCOPY=${OBJCOPY:-$(command -v llvm-objcopy)}
export PATH="$FLUTTER_ROOT/bin:$PATH" CI=true FLUTTER_SUPPRESS_ANALYTICS=true
NAME=$(sed -n 's/^name: *//p' "$APP/pubspec.yaml" | head -1)

rm -rf "$OUT" && mkdir -p "$OUT/build/arm64/App.framework" "$OUT/App.framework"
B=$OUT/build

echo "== 1. kernel (KernelSnapshot, iOS release)"
(cd "$APP" && "$C/dart-sdk/bin/dartaotruntime" "$C/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot" \
  --sdk-root "$C/artifacts/engine/common/flutter_patched_sdk_product/" \
  --target=flutter --no-print-incremental-dependencies \
  -Ddart.vm.profile=false -Ddart.vm.product=true \
  --delete-tostring-package-uri=dart:ui --delete-tostring-package-uri=package:flutter \
  --aot --tfa --target-os ios \
  --packages "$APP/.dart_tool/package_config.json" \
  --output-dill "$B/app.dill" --depfile "$B/kernel_snapshot_program.d" --verbosity=error \
  "package:$NAME/main.dart")

echo "== 2. AOT (AOTSnapshotter, app-aot-macho-dylib)"
(cd "$B" && "$GS" --deterministic \
  --snapshot_kind=app-aot-macho-dylib \
  --macho=arm64/App.framework/App \
  --macho-object=arm64/app.o \
  --macho-min-os-version=15.0 \
  --macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks \
  --macho-install-name=@rpath/App.framework/App \
  app.dill)

echo "== 3. dSYM + strip -x (release), then lipo (single arch = copy)"
# gen_snapshot records arm64/app.o relative to its working directory, so run dsymutil there.
(cd "$B" && "$DSYMUTIL" -o arm64/App.framework.dSYM arm64/App.framework/App)
"$OBJCOPY" --discard-all "$B/arm64/App.framework/App" "$B/arm64/App.stripped"   # == strip -x
cp "$B/arm64/App.stripped" "$OUT/App.framework/App"
mkdir -p "$OUT/App.framework.dSYM" && cp -r "$B/arm64/App.framework.dSYM/." "$OUT/App.framework.dSYM/"

echo "== 4. flutter_assets (iOS, release)"
(cd "$APP" && flutter build bundle --release --target-platform ios \
  --asset-dir "$OUT/App.framework/flutter_assets" > "$B/bundle.log" 2>&1) || { cat "$B/bundle.log"; exit 1; }

echo "== 5. Info.plist (AppFrameworkInfo.plist + MinimumOSVersion, as plutil -replace does)"
python3 - "$APP/ios/Flutter/AppFrameworkInfo.plist" "$OUT/App.framework/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    p = plistlib.load(f)
p["MinimumOSVersion"] = "15.0"
with open(sys.argv[2], "wb") as f:
    plistlib.dump(p, f, fmt=plistlib.FMT_XML)
PY

echo "== 6. codesign: NOT done here (flutter_tools: codesign --force --sign <id or ->). Spike B signs with zsign."
echo "== result"
find "$OUT/App.framework" -maxdepth 1 | sort
file "$OUT/App.framework/App"
ls -l "$B/arm64/App.framework/App" "$OUT/App.framework/App"
du -sh "$OUT/App.framework"

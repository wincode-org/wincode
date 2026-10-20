#!/usr/bin/env bash
# Spike E: a Flutter app -> unsigned CounterRunner.app and .ipa, entirely on Linux. The spike B
# pipeline (spike A's make_app.sh + the spike B runner), plus the app's Dart build hooks: run for
# iOS arm64 by run_hooks with the xcrun shim, each dylib wrapped as a framework the way
# flutter_tools 3.47.7 does it on macOS (isolated/native_assets/ios/native_assets.dart), and the
# native-assets manifest shipped as flutter_assets/NativeAssetsManifest.json (build_system/targets/ios.dart).
# Signing and install happen later, with xtool.
# Usage: [BUNDLE_APP=<copy without hook packages>] assemble.sh <app-dir> <out-dir>
# (BUNDLE_APP: see make_apps.sh, hooks_app_bundle; spike A's make_app.sh builds flutter_assets from it.)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
APP=$(cd "$1" && pwd)
OUT=$2
SPIKE_A=${SPIKE_A:-$HOME/spikes/spike-a}
DART=$SPIKE_A/flutter/bin/cache/dart-sdk/bin/dart
TOOLSET=$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/toolset/bin
LLVM=$HOME/.local/share/swiftly/toolchains/6.4.0/usr/bin
rm -rf "$OUT" && mkdir -p "$OUT/frameworks"
OUT=$(cd "$OUT" && pwd)

echo "== 1. build hooks, iOS arm64"
cp -r "$HERE/run_hooks" "$OUT/run_hooks" && (cd "$OUT/run_hooks" && "$DART" pub get >/dev/null)
"$DART" run "$OUT/run_hooks/bin/run_hooks.dart" "$APP" "$OUT/assets.json" \
  "$HERE/clang-ios" "$TOOLSET/ld64.lld" "$LLVM/llvm-ar" "$HERE/shim" 2>"$OUT/hooks.log"

echo "== 2. a framework per dylib (dSYM, strip -x, @rpath install name, Info.plist) + manifest"
python3 - "$OUT/assets.json" "$OUT/frameworks" "$OUT/native_assets.json" "$TOOLSET/dsymutil" "$LLVM/llvm-objcopy" <<'PY'
import json, os, plistlib, re, shutil, struct, subprocess, sys

assets_json, fw_root, manifest_path, dsymutil, objcopy = sys.argv[1:]
LC_ID_DYLIB = 0xD

def set_install_name(path, name):
    """Rewrite LC_ID_DYLIB in place (what install_name_tool -id does when the name fits)."""
    data = bytearray(open(path, "rb").read())
    magic, _, _, _, ncmds = struct.unpack_from("<IiiII", data, 0)
    assert magic == 0xFEEDFACF, "not a 64-bit little-endian Mach-O"
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_ID_DYLIB:
            start = off + struct.unpack_from("<I", data, off + 8)[0]
            room = off + size - start
            new = name.encode() + b"\0"
            assert len(new) <= room, f"install name needs {len(new)} bytes, {room} available"
            data[start:off + size] = new.ljust(room, b"\0")
            open(path, "wb").write(data)
            return
        off += size
    raise SystemExit(f"{path}: no LC_ID_DYLIB")

manifest = {"format-version": [1, 0, 0], "native-assets": {}}
for asset in json.load(open(assets_json)):
    if asset["linkMode"] != "bundled":
        raise SystemExit(f"unsupported link mode for {asset['id']}: {asset['linkMode']}")
    # frameworkUri(): drop .dylib and a leading "lib", keep [A-Za-z0-9._-].
    name = re.sub(r"\.dylib$", "", os.path.basename(asset["file"]))
    if asset["file"].endswith(".dylib") and name.startswith("lib"):
        name = name[3:]
    name = re.sub(r"[^A-Za-z0-9._-]", "", name)
    fw = os.path.join(fw_root, f"{name}.framework")
    os.makedirs(fw)
    binary = os.path.join(fw, name)
    shutil.copy(asset["file"], binary)
    subprocess.run([dsymutil, binary, "-o", f"{fw}.dSYM"], check=True)
    subprocess.run([objcopy, "--discard-all", binary], check=True)  # == strip -x
    set_install_name(binary, f"@rpath/{name}.framework/{name}")
    with open(os.path.join(fw, "Info.plist"), "wb") as f:
        plistlib.dump({
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": name,
            "CFBundleIdentifier": f"io.flutter.flutter.native_assets.{name}".replace("_", "-"),
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": name,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleSignature": "????",
            "CFBundleVersion": "1.0",
            "MinimumOSVersion": "15.0",
        }, f)
    manifest["native-assets"].setdefault("ios_arm64", {})[asset["id"]] = ["absolute", f"{name}.framework/{name}"]
    print(f"{asset['id']} -> {name}.framework")
json.dump(manifest, open(manifest_path, "w"), indent=2)
PY

echo "== 3. App.framework (spike A: kernel + gen_snapshot + flutter_assets) + NativeAssetsManifest.json"
SPIKE="$SPIKE_A" bash "$REPO/spikes/a-gen-snapshot/make_app.sh" "$APP" "$OUT/app-framework" >"$OUT/make_app.log" 2>&1 \
  || { tail -30 "$OUT/make_app.log"; exit 1; }
ASSETS_DIR=$OUT/app-framework/App.framework/flutter_assets
if [ -f "$ASSETS_DIR/NativeAssetsManifest.json" ]; then
  cp "$ASSETS_DIR/NativeAssetsManifest.json" "$OUT/flutter-build-bundle.NativeAssetsManifest.json"
fi
cp "$OUT/native_assets.json" "$ASSETS_DIR/NativeAssetsManifest.json"

echo "== 4. runner (spike B), then embed the native-asset frameworks"
SPIKE_A="$SPIKE_A" bash "$REPO/spikes/b-device/stage.sh" "$OUT/runner" >/dev/null
SPIKE_A="$SPIKE_A" APP_FW="$OUT/app-framework/App.framework" bash "$REPO/spikes/b-device/build.sh" "$OUT/runner" >"$OUT/runner-build.log" 2>&1 \
  || { tail -30 "$OUT/runner-build.log"; exit 1; }
RUNNER_APP=$OUT/runner/xtool/CounterRunner.app
for fw in "$OUT"/frameworks/*.framework; do
  [ -e "$fw" ] && cp -r "$fw" "$RUNNER_APP/Frameworks/"
done

echo "== 5. unsigned .ipa"
NAME=$(basename "$APP")
(cd "$OUT" && rm -rf Payload && mkdir Payload && cp -r "$RUNNER_APP" Payload/ && zip -qry "$NAME-unsigned.ipa" Payload && rm -rf Payload)

echo "== result"
grep -h "^INFO: .*Running: " "$OUT/hooks.log" | sed -E 's/^INFO: [^:]+:[^:]+:[^:]+: //; s#'"$HOME"'#~#g' | cut -c1-200 || true
echo "app.dill: $(stat -c %s "$OUT/app-framework/build/app.dill") bytes"
find "$RUNNER_APP/Frameworks" -maxdepth 2 \( -name '*.framework' -o -name 'App' -o -name 'Flutter' \) | sed "s#$RUNNER_APP/##" | sort
for fw in "$RUNNER_APP"/Frameworks/*.framework; do
  bin=$fw/$(basename "$fw" .framework)
  echo "-- $(basename "$fw"): $(file -b "$bin")"
  if [ -d "$OUT/frameworks/$(basename "$fw")" ]; then
    "$LLVM/llvm-objdump" --macho --private-headers "$bin" \
      | grep -A5 -E "cmd LC_(BUILD_VERSION|ID_DYLIB|LOAD_DYLIB|CODE_SIGNATURE)$" | grep -E "cmd |platform|minos|sdk|name" | sed 's/^ *//'
  fi
done
echo "-- NativeAssetsManifest.json"; cat "$ASSETS_DIR/NativeAssetsManifest.json"; echo
ls -l "$OUT/$NAME-unsigned.ipa"

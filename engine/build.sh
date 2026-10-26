#!/usr/bin/env bash
# Build the iOS arm64 gen_snapshot for a Flutter release, on Linux x64 (ADR-0004), from the Dart SDK that sync.sh fetched.
# Only the host-toolchain gen_snapshot is built. The tool is installed in
#   $WINCODE_HOME/engines/<engine version>/gen_snapshot   (with info.txt beside it)
#
# Usage: engine/build.sh <Flutter SDK folder>
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FLUTTER=$(cd "${1:?usage: build.sh <Flutter SDK folder>}" && pwd)
HOME_DIR=${WINCODE_HOME:-$HOME/.wincode}
ENGINE=$(tr -d '[:space:]' < "$FLUTTER/bin/internal/engine.version")
DREV=$(sed -n "s/^ *'dart_revision': '\([0-9a-f]\{40\}\)'.*/\1/p" "$FLUTTER/DEPS" | head -1)
WORK=$HOME_DIR/engine-build/${ENGINE:0:10}
SDK=$WORK/dart-sdk/sdk
OUT=$SDK/out/ProductIOSARM64Linux
[ -d "$SDK" ] || { echo "run sync.sh first: $SDK does not exist" >&2; exit 1; }
[ "$(git -C "$SDK" rev-parse HEAD)" = "$DREV" ] || { echo "the Dart checkout is not at $DREV" >&2; exit 1; }

cd "$SDK"
# GN-only patches (no C++ changes). Each anchor must match exactly once; re-runs are no-ops. If Dart changes these
# lines the script stops, and the edits have to be refreshed.
python3 - <<'PY'
import pathlib, sys
TAG = "winCode ADR-0004"
patches = {
  "build/config/BUILDCONFIG.gn": [
    # Linux host + target_os=ios: use the Linux clang toolchains and never load //build/toolchain/mac.
    ('  import("//build/config/ios/ios_sdk.gni")  # For use_simulator\n'
     '  host_toolchain = "//build/toolchain/mac:clang_$host_cpu"\n',
     '  import("//build/config/ios/ios_sdk.gni")  # For use_simulator\n'
     '  if (host_os == "linux") {\n'
     f'    # {TAG}: Linux-hosted iOS cross gen_snapshot.\n'
     '    host_toolchain = "//build/toolchain/linux:clang_$host_cpu"\n'
     '  } else {\n'
     '    host_toolchain = "//build/toolchain/mac:clang_$host_cpu"\n'
     '  }\n'),
    # The default toolchain must differ from host_toolchain; nothing is built in it.
    ('  set_default_toolchain("//build/toolchain/mac:$toolchain_target")\n',
     '  if (host_os == "linux") {\n'
     f'    # {TAG}: placeholder default toolchain, never built.\n'
     '    set_default_toolchain("//build/toolchain/linux:clang_$target_cpu")\n'
     '  } else {\n'
     '    set_default_toolchain("//build/toolchain/mac:$toolchain_target")\n'
     '  }\n'),
  ],
  "build/config/compiler/BUILD.gn": [
    # The clang version stamp must follow the host-installed clang, not is_ios.
    ('    } else if ((is_mac || is_ios) && host_cpu == "arm64") {\n',
     '    } else if ((is_mac || is_ios) && host_os == "linux") {\n'
     f'      # {TAG}: Linux-hosted iOS configuration uses the Linux clang.\n'
     '      toolchain_stamp_file =\n'
     '          "//buildtools/linux-x64/clang/.versions/clang.cipd_version"\n'
     '    } else if ((is_mac || is_ios) && host_cpu == "arm64") {\n'),
  ],
}
for path, reps in patches.items():
    p = pathlib.Path(path); s = p.read_text()
    for old, new in reps:
        if new in s:
            continue
        if s.count(old) != 1:
            sys.exit(f"patch anchor not found exactly once in {path}: {old[:70]!r}")
        s = s.replace(old, new)
    p.write_text(s)
print("GN patches applied")
PY

# A one-target root so GN only defines gen_snapshot's dependency graph in the default (iOS) toolchain. Unrelated
# targets (samples, ffi test libraries) assume Apple .dylib names when is_ios and fail GN's generated-input check.
mkdir -p wincode_engine
cat > wincode_engine/BUILD.gn <<'GNFILE'
# winCode: build only the host-toolchain gen_snapshot.
group("gen_snapshot_ios") {
  deps = [ "//runtime/bin:gen_snapshot($host_toolchain)" ]
}
GNFILE

mkdir -p "$OUT"
sed "s/@DART_SDK_VERIFICATION_HASH@/${DREV:0:10}/" "$HERE/args.gn" > "$OUT/args.gn"
GN=$SDK/buildtools/gn
NINJA=$SDK/buildtools/ninja/ninja
"$GN" gen "$OUT" --root-target=//wincode_engine --root-pattern=//wincode_engine:*
TARGET=$("$GN" outputs "$OUT" "//runtime/bin:gen_snapshot(//build/toolchain/linux:clang_x64)" | head -1)
T0=$(date +%s)
nice -n 10 "$NINJA" -C "$OUT" -j "$(nproc)" "$TARGET"
echo "build_seconds=$(( $(date +%s) - T0 ))"

# The tool must be the Dart that the Flutter release ships: the kernel carries that Dart's hash.
GOT=$("$OUT/$TARGET" --version 2>&1 | sed -n 's/^Dart SDK version: \([0-9.]*\).*/\1/p')
WANT=$(tr -d '[:space:]' < "$FLUTTER/bin/cache/dart-sdk/version")
[ "$GOT" = "$WANT" ] || { echo "gen_snapshot is Dart $GOT, but Flutter ships Dart $WANT" >&2; exit 1; }

DEST=$HOME_DIR/engines/$ENGINE
mkdir -p "$DEST"
cp "$OUT/$TARGET" "$DEST/gen_snapshot"
{
  echo "flutter engine: $ENGINE"
  echo "dart revision:  $DREV"
  echo "dart version:   $GOT"
  echo "sdk hash:       ${DREV:0:10}"
} > "$DEST/info.txt"
file "$DEST/gen_snapshot"
ls -l "$DEST/gen_snapshot"
du -sh "$WORK"

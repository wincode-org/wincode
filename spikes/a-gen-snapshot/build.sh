#!/usr/bin/env bash
# Spike A1: configure and build only the host-toolchain gen_snapshot
# (runs on Linux x64, generates iOS arm64 code) from the standalone Dart SDK.
set -euo pipefail
SPIKE=${SPIKE:-$HOME/spikes/spike-a}
HERE=$(cd "$(dirname "$0")" && pwd)
SDK=$SPIKE/dart-sdk/sdk
OUT=$SDK/out/ProductIOSARM64Linux
GN=$SDK/buildtools/gn
NINJA=$SDK/buildtools/ninja/ninja

cd "$SDK"
# GN-only patches (no C++ changes). Each anchor must match exactly once; re-runs are no-ops.
python3 - <<'PY'
import pathlib, sys
TAG = "winCode spike A"
patches = {
  "build/config/BUILDCONFIG.gn": [
    # Linux host + target_os=ios: use the Linux clang toolchains and never load
    # //build/toolchain/mac (it asserts host_os == "mac").
    ('  import("//build/config/ios/ios_sdk.gni")  # For use_simulator\n'
     '  host_toolchain = "//build/toolchain/mac:clang_$host_cpu"\n',
     '  import("//build/config/ios/ios_sdk.gni")  # For use_simulator\n'
     '  if (host_os == "linux") {\n'
     f'    # {TAG}: Linux-hosted iOS cross gen_snapshot.\n'
     '    host_toolchain = "//build/toolchain/linux:clang_$host_cpu"\n'
     '  } else {\n'
     '    host_toolchain = "//build/toolchain/mac:clang_$host_cpu"\n'
     '  }\n'),
    # The default toolchain must differ from host_toolchain: GN ignores
    # toolchain_args for the default toolchain, and the host toolchain needs
    # current_os=linux / current_cpu=x64. Nothing is built in the default one.
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

# A one-target root so GN only defines gen_snapshot's dependency graph in the
# default (iOS) toolchain. Unrelated targets (samples, ffi test libraries)
# assume Apple .dylib names when is_ios and fail GN's generated-input check.
mkdir -p wincode_spike
cat > wincode_spike/BUILD.gn <<'GNFILE'
# winCode spike A: build only the host-toolchain gen_snapshot.
group("gen_snapshot_ios") {
  deps = [ "//runtime/bin:gen_snapshot($host_toolchain)" ]
}
GNFILE
git diff --stat

mkdir -p "$OUT"
cp "$HERE/args.gn" "$OUT/args.gn"
"$GN" gen "$OUT" --root-target=//wincode_spike --root-pattern=//wincode_spike:*
LABEL="//runtime/bin:gen_snapshot(//build/toolchain/linux:clang_x64)"
TARGET=$("$GN" outputs "$OUT" "$LABEL" | head -1)
echo "ninja target: $TARGET"
T0=$(date +%s)
nice -n 10 "$NINJA" -C "$OUT" -j "$(nproc)" "$TARGET"
echo "build_seconds=$(( $(date +%s) - T0 ))"
file "$OUT/$TARGET"
du -sh "$OUT"

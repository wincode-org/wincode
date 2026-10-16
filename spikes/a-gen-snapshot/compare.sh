#!/usr/bin/env bash
# Spike A1: run the Linux-built gen_snapshot on the macOS oracle's app.dill with the
# exact flutter_tools iOS release args and output names, then compare byte for byte.
# Usage: compare.sh <oracle-artifact-dir>
set -uo pipefail
SPIKE=${SPIKE:-$HOME/spikes/spike-a}
ORACLE=$(cd "${1:?oracle artifact dir}" && pwd)
GS=${GS:-$SPIKE/dart-sdk/sdk/out/ProductIOSARM64Linux/clang_x64/gen_snapshot}
WORK=$SPIKE/compare/linux
HASH=0451907c2eaa8467e848c0067bfe8ed4
FEATURES="product no-asan no-msan no-tsan no-shared_data no-code_comments no-dwarf_stack_traces arm64 ios no-compressed-pointers"

echo "== gen_snapshot"; file "$GS"; "$GS" --version
rm -rf "$WORK" && mkdir -p "$WORK/arm64/App.framework"
cp "$ORACLE/app.dill" "$WORK/app.dill"
cd "$WORK"
cmd=("$GS" --deterministic
  --snapshot_kind=app-aot-macho-dylib
  --macho=arm64/App.framework/App
  --macho-object=arm64/app.o
  --macho-min-os-version=15.0
  --macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks
  --macho-install-name=@rpath/App.framework/App
  app.dill)
printf '%q ' "${cmd[@]}"; echo
"${cmd[@]}"; echo "gen_snapshot_exit=$?"

echo "== sha256"
sha256sum "$ORACLE/app.dill" app.dill "$ORACLE/arm64/App.framework/App" arm64/App.framework/App "$ORACLE/arm64/app.o" arm64/app.o

echo "== snapshot header (hash + features) in our App"
HDR=$(strings -a -n 20 arm64/App.framework/App | grep -m1 "^$HASH" || true)
echo "$HDR"
[ "$HDR" = "$HASH$FEATURES" ] && echo "GATE hash+features: MATCH" || echo "GATE hash+features: MISMATCH"

echo "== cmp"
for f in arm64/App.framework/App arm64/app.o; do
  if cmp -s "$ORACLE/$f" "$f"; then echo "$f: BYTE-IDENTICAL"; else echo "$f: DIFFERENT"; cmp -l "$ORACLE/$f" "$f" | wc -l | sed 's/^/  differing bytes: /'; DIFF=1; fi
done

if [ "${DIFF:-0}" = 1 ]; then
  echo "== load command diff (oracle vs linux)"
  diff <(llvm-objdump --macho --private-headers "$ORACLE/arm64/App.framework/App") \
       <(llvm-objdump --macho --private-headers arm64/App.framework/App) | head -60
  echo "== per-section comparison"
  for s in __TEXT,__text __TEXT,__const __TEXT,__unwind_info __DATA,__const; do
    a=$(llvm-objdump --macho --section="$s" -s "$ORACLE/arm64/App.framework/App" 2>/dev/null | sha256sum | cut -c1-16)
    b=$(llvm-objdump --macho --section="$s" -s arm64/App.framework/App 2>/dev/null | sha256sum | cut -c1-16)
    echo "$s oracle=$a linux=$b $([ "$a" = "$b" ] && echo same || echo DIFFERENT)"
  done
fi

echo "== Mach-O checks on our App"
A=arm64/App.framework/App
file "$A"
llvm-objdump --macho --private-headers "$A" > hdrs.txt
grep -A6 "cmd LC_BUILD_VERSION" hdrs.txt | grep -E "platform|minos|sdk"
grep -A3 "cmd LC_ID_DYLIB" hdrs.txt | grep name
grep -A3 "cmd LC_RPATH" hdrs.txt | grep path
for lc in LC_UUID LC_ENCRYPTION_INFO_64 LC_CODE_SIGNATURE LC_ID_DYLIB LC_BUILD_VERSION; do
  printf '%-22s %s\n' "$lc" "$(grep -c "cmd $lc\$" hdrs.txt)"
done
grep -A3 "cmd LC_UUID" hdrs.txt | grep uuid
echo "== exported snapshot symbols"
# Flutter 3.47.7 engine looks these up (runtime/dart_snapshot.cc): one text and one data symbol
# for both VM and isolate snapshots.
llvm-nm --extern-only --defined-only "$A"

# Optional: the oracle run that interposed a glibc-style stable qsort into the official
# macOS gen_snapshot (diag/thin-stable-qsort). Byte-identical means the only host
# difference is qsort tie-breaking (macOS libc vs glibc).
Q="$ORACLE/diag/thin-stable-qsort/arm64"
if [ -d "$Q" ]; then
  echo "== vs official macOS gen_snapshot with glibc-style qsort"
  for f in App.framework/App app.o; do
    cmp -s "$Q/$f" "arm64/$f" && echo "$f: BYTE-IDENTICAL" || echo "$f: DIFFERENT ($(cmp -l "$Q/$f" "arm64/$f" | wc -l) bytes)"
  done
  echo "app.o DWARF producer strings:"; strings -a "$Q/app.o" | grep -m1 "^Dart [0-9]"; strings -a arm64/app.o | grep -m1 "^Dart [0-9]"
fi

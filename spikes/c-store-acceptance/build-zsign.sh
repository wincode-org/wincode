#!/usr/bin/env bash
# Spike C: build the zsign command line in WSL from the commit xtool pins, checked by that commit and by the
# SHA-256 of GitHub's source archive for it (its content matched xtool's own checkout on 2026-10-23).
#   build-zsign.sh <dir>     builds <dir>/zsign-<commit>/bin/zsign
# Needs Ubuntu's make and libssl-dev. Compiles with the Swift toolchain's clang, since g++ isn't installed.
set -euo pipefail
COMMIT=f6158be9e62a5ce2a53d72b1a6d880880da956c8  # xtool-org/zsign 1.9.0, as in third_party/xtool/Package.resolved
SHA256=423ebe2f4dd3380367461c03e6de3b9e9f31adcbe9a2f0237493c8f0bf9b7c5d
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SWIFT_BIN=${SWIFT_BIN:-$HOME/.local/share/swiftly/toolchains/6.4.0/usr/bin}
grep -q "\"revision\" : \"$COMMIT\"" "$REPO/third_party/xtool/Package.resolved" || { echo "xtool no longer pins $COMMIT" >&2; exit 1; }
mkdir -p "$1" && cd "$1"
[ -f "zsign-$COMMIT.tar.gz" ] || curl -fsSL -o "zsign-$COMMIT.tar.gz" "https://github.com/xtool-org/zsign/archive/$COMMIT.tar.gz"
echo "$SHA256  zsign-$COMMIT.tar.gz" | sha256sum -c --quiet - || { echo "checksum mismatch: not building" >&2; exit 1; }
rm -rf "zsign-$COMMIT" && tar xzf "zsign-$COMMIT.tar.gz"
make -s -C "zsign-$COMMIT/build/linux" CXX="$SWIFT_BIN/clang++" CC="$SWIFT_BIN/clang" VERSION=1.9.0 >/dev/null
"$PWD/zsign-$COMMIT/bin/zsign" --version
echo "$PWD/zsign-$COMMIT/bin/zsign"

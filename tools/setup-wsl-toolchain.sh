#!/usr/bin/env bash
# Rebuild winCode's WSL2 toolchain: apt packages, Swift (swiftly), xtool and the Darwin SDK
# built from the user's own Xcode.xip. Idempotent: rerun after any failure, finished steps are skipped.
# It never logs in to Apple: run `xtool auth login` yourself afterwards.
#
# Fresh distro (from Windows):
#   wsl --install -d Ubuntu-24.04 --location C:\wsl\Ubuntu-24.04 --no-launch
#   wsl -d Ubuntu-24.04 -u root -- env WSL_USER=<name> bash /mnt/c/<repo>/tools/setup-wsl-toolchain.sh /mnt/c/<path>/Xcode.xip
#   wsl --terminate Ubuntu-24.04    (starts systemd and the default user on next launch)
# Not done here, Windows side: .wslconfig networkingMode=mirrored and Apple Devices (ADR-0005).
set -euo pipefail

SWIFT_VERSION=${SWIFT_VERSION:-6.4.0}   # what spikes A and B ran on
XTOOL_VERSION=1.22.2                    # first release with working Apple ID login (-80045)
# SHA-256 GitHub records for the release asset (gh api repos/xtool-org/xtool/releases/tags/1.22.2).
XTOOL_SHA256=e3176cdf861f58b7f135c755c7bfaec92d0568ef826027b4e5e3d82b3219ddfe
WSL_USER=${WSL_USER:-$(id -nu 1000 2>/dev/null || true)}
SELF=$(readlink -f "$0")
CACHE=/var/cache/wincode

step() { printf '\n== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# Resumable download: fetch <url> <file>. The network here drops long transfers.
fetch() {
  local i
  for i in 1 2 3 4 5; do
    curl -fL -C - -o "$2" "$1" && return 0
    echo "download interrupted, resuming ($i/5)"
    sleep 5
  done
  return 1
}

# --- root steps ---

wsl_user() {
  step "WSL user $WSL_USER"
  # No password: admin work goes through `wsl -u root`.
  id "$WSL_USER" >/dev/null 2>&1 || { useradd -m -G sudo -s /bin/bash "$WSL_USER" && passwd -d "$WSL_USER" >/dev/null; }
  local conf
  conf=$(printf '[boot]\nsystemd=true\n\n[user]\ndefault=%s\n' "$WSL_USER")
  [[ -f /etc/wsl.conf && $(cat /etc/wsl.conf) == "$conf" ]] || echo "$conf" >/etc/wsl.conf
}

apt_packages() {
  step "apt packages"
  # Swift's dependencies on Ubuntu 24.04 (swift.org/install/linux), FUSE for the xtool AppImage,
  # libimobiledevice-utils for device checks (idevice_id). No usbmuxd: the device link is
  # Apple's Windows service (ADR-0005).
  local pkgs=(binutils ca-certificates curl file git gnupg2 libc6-dev libcurl4-openssl-dev libedit2
    libgcc-13-dev libncurses-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev
    pkg-config tzdata unzip zip zlib1g-dev libfuse2t64 libimobiledevice-utils)
  if dpkg -s "${pkgs[@]}" >/dev/null 2>&1; then echo "already installed"; return; fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

install_xtool() {
  step "xtool $XTOOL_VERSION"
  local bin=/usr/local/bin/xtool dl=$CACHE/xtool-$XTOOL_VERSION-x86_64.AppImage
  [[ $(uname -m) == x86_64 ]] || die "only x86_64 is pinned, got $(uname -m)"
  if [[ -f $bin ]] && echo "$XTOOL_SHA256  $bin" | sha256sum -c --status; then echo "already installed"; return; fi
  mkdir -p "$CACHE"
  if ! echo "$XTOOL_SHA256  $dl" | sha256sum -c --status 2>/dev/null; then
    fetch "https://github.com/xtool-org/xtool/releases/download/$XTOOL_VERSION/xtool-x86_64.AppImage" "$dl" \
      || { rm -f "$dl"; die "xtool download failed; rerun to retry"; }
    echo "$XTOOL_SHA256  $dl" | sha256sum -c --status || { rm -f "$dl"; die "xtool download does not match the pinned SHA-256"; }
  fi
  install -m 0755 "$dl" "$bin"
  xtool --version
}

# --- user steps (run through as_user) ---

swift_toolchain() {
  step "Swift $SWIFT_VERSION (swiftly)"
  if ! command -v swiftly >/dev/null; then
    local dir
    dir=$(mktemp -d)
    fetch https://download.swift.org/swiftly/linux/swiftly-x86_64.tar.gz "$dir/swiftly.tar.gz"
    fetch https://download.swift.org/swiftly/linux/swiftly-x86_64.tar.gz.sig "$dir/swiftly.tar.gz.sig"
    # --compressed: swift.org sends this file gzip-encoded even when not asked to.
    curl -fsSL --compressed https://www.swift.org/keys/all-keys.asc | gpg --batch --quiet --import -
    gpg --batch --verify "$dir/swiftly.tar.gz.sig" "$dir/swiftly.tar.gz"
    tar -xzf "$dir/swiftly.tar.gz" -C "$dir"
    "$dir/swiftly" init --assume-yes --skip-install --quiet-shell-followup </dev/null
    rm -rf "$dir"
    . "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
  fi
  local post
  post=$(mktemp -d)/post-install.sh
  swiftly install "$SWIFT_VERSION" --assume-yes --post-install-file "$post" </dev/null
  # The apt list above should cover Swift's dependencies; stop if swiftly still wants more.
  [[ ! -s $post ]] || die "swiftly needs more system packages; install them as root, then rerun:"$'\n'"$(cat "$post")"
  rm -rf "$(dirname "$post")"
  swiftly use "$SWIFT_VERSION" </dev/null
  hash -r
  swift --version
}

darwin_sdk() {
  step "Darwin SDK"
  local status
  status=$(xtool sdk status)
  if [[ $status == *"Darwin SDK is installed"* ]]; then echo "$status"; return; fi
  [[ -n ${1:-} && -f $1 ]] || die "no Darwin SDK yet: pass the path to Xcode.xip as the first argument"
  xtool sdk install "$1" </dev/null
  xtool sdk status
}

smoke_test() {
  step "smoke test: unsigned build of a new app"
  local dir app
  dir=$(mktemp -d)
  (cd "$dir" && xtool new hello --skip-setup </dev/null >/dev/null && cd hello && xtool dev build </dev/null)
  app=$(find "$dir/hello/xtool" -maxdepth 1 -name '*.app' | head -1)
  [[ -n $app ]] || die "xtool dev build produced no .app"
  file "$app/$(basename "$app" .app)"
  rm -rf "$dir"
}

as_user() {
  runuser -l "$WSL_USER" -c "$(printf '%q ' env SWIFT_VERSION="$SWIFT_VERSION" bash "$SELF" --as-user "$@")"
}

if [[ ${1:-} == --as-user ]]; then
  shift
  env_sh=${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh
  if [[ -f $env_sh ]]; then . "$env_sh"; fi
  "$@"
  exit
fi

[[ $(id -u) -eq 0 ]] || die "run as root: wsl -d Ubuntu-24.04 -u root -- bash $0 <Xcode.xip>"
[[ -n $WSL_USER ]] || die "no user with UID 1000: set WSL_USER=<name>"
wsl_user
apt_packages
install_xtool
as_user swift_toolchain
as_user darwin_sdk "${1:-}"
as_user smoke_test
printf '\nDone in %d min. Next, yourself: xtool auth login\n' $((SECONDS / 60))

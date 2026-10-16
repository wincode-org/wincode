# Spike: xtool in WSL2 (day 2)

Date: 2026-10-12. Goal: confirm that xtool can build an iOS arm64 app on Windows via WSL2 using our own Xcode download. No device was used.

## Result

A stock `xtool new` hello-world built for `arm64-apple-ios` in WSL2 Ubuntu 24.04. The output is an unsigned `.app` containing a Mach-O arm64 executable. Not yet tested: signing, installing, running on a device.

## Environment

| Item | Value |
| --- | --- |
| Windows | 11 Home, build 26300 |
| WSL | 2.7.11.0, kernel 6.18.33.2 |
| Distro | Ubuntu 24.04.5 LTS, on drive D: (`wsl --install --location`) |
| WSL limits | `.wslconfig`: `memory=11GB`, `processors=12` |
| xtool | 1.21.0 (AppImage from the release tag, not "latest") |
| Swift | 6.4 (swift-6.4-RELEASE), installed with swiftly |
| Xcode input | Xcode 26.6 `.xip`, downloaded by the user from Apple |
| Login mode | App Store Connect API key |

xtool's own docs (`Installation-Linux.md` at the 1.21.0 tag) name Xcode 27 and Swift 6.4. Xcode 26.6 was accepted anyway: xtool has no Xcode version check and only looks for `iPhoneOS<N.N>.sdk`.

## Darwin SDK

Built by `xtool setup` from the `.xip` into `~/.swiftpm/swift-sdks/darwin.artifactbundle` (7.8 GB; it keeps a copy of `Xcode.app/Contents/Developer`, so it looks like a full rather than slim SDK). `swift sdk list` shows `darwin`. SDK metadata: `epoch=3,darwinTools=1.1.0,oam=1.3.0`.

| Platform | SDK directories |
| --- | --- |
| iPhoneOS | `iPhoneOS.sdk`, `iPhoneOS26.5.sdk` |
| iPhoneSimulator | `iPhoneSimulator.sdk`, `iPhoneSimulator26.5.sdk` |
| MacOSX | `MacOSX.sdk`, `MacOSX26.sdk`, `MacOSX26.5.sdk` |

So the Xcode 26.6 download contains the iOS 26.5 SDK.

## Commands

Run inside Ubuntu, in a login shell, on the Linux filesystem (not `/mnt/c`):

```bash
mkdir -p ~/projects && cd ~/projects
xtool new hello-xtool --skip-setup
cd hello-xtool
xtool dev build
```

- `--skip-setup` stops `xtool new` from starting the login and SDK steps.
- `xtool dev build` builds with SwiftPM and writes `xtool/hello_xtool.app`. Options: `-c release`, `-s` (codesign), `-i` (`.ipa`), `--triple`. Only the default (unsigned `.app`, debug) was used here.

## Build results

| Measure | Value |
| --- | --- |
| First build | 52 s (SwiftPM builds the iOS SDK modules) |
| Rebuild after touching one file | 1.8 s build, about 4 s wall |
| Warnings | none |
| Output | `~/projects/hello-xtool/xtool/hello_xtool.app` (100 KB) |
| Executable | Mach-O 64-bit arm64, PIE |
| `.ipa` | not produced (needs `--ipa`) |

Generated template: `Package.swift` (iOS 17, macOS 14), `xtool.yml` (`bundleID`), SwiftUI sources.

### Finding: no Xcode build metadata in Info.plist

The built `Info.plist` has these keys only: `CFBundleDevelopmentRegion`, `CFBundleDisplayName`, `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleInfoDictionaryVersion`, `CFBundleName`, `CFBundlePackageType`, `CFBundleShortVersionString`, `CFBundleSupportedPlatforms`, `CFBundleVersion`, `LSRequiresIPhoneOS`, `MinimumOSVersion`, `UIDeviceFamily`, `UILaunchScreen`, `UIRequiredDeviceCapabilities`, `UISupportedInterfaceOrientations`.

It has none of the `DTSDK*`, `DTXcode*`, `DTPlatform*`, `DTCompiler` or `BuildMachineOSBuild` keys that Xcode writes. This is relevant to the App Store "build metadata" gate in `docs/PLAN.md`. We have to decide what to write there, using only true values from the user's own Xcode.

## Gotchas

- **WSL needs a real user.** xtool keeps its config and the SDK per user (`~/.config/xtool`, `~/.swiftpm`), so set up a normal user rather than relying on root. Set the user as default in `/etc/wsl.conf` (`[user] default=...`).
- **Keep the clock in sync.** Clock drift breaks Apple login. Check with `timedatectl` before debugging login errors. Restarting WSL (`wsl --shutdown`) is the likely fix after sleep or hibernate, but it was not verified.
- **Password login failed with Apple error `-80045`** ("This action cannot be completed at this time"). Apple rejected xtool's client identity server-side, for every account. It is fixed in xtool 1.22.2 (xtool-org/xtool#329, fixed by #337 and #340); see `spike-b-device.md`.
- **Swift via swiftly.** `swiftly init` already installs the latest Swift (6.4.0 here) and prints a list of extra system packages to install as root (`zip gnupg2 libpython3-dev pkg-config zlib1g-dev`).
- **AppImage needs FUSE.** `libfuse2t64` on Ubuntu 24.04.
- **Piping scripts from PowerShell to WSL adds CRLF line endings** and breaks them. Pipe from Git Bash, or write the script file with LF endings.
- **Disk.** The WSL disk image on D: was 6.7 GB before the SDK. The SDK adds about 8 GB, so keep several GB free on the drive that holds the distro.
- **Use `--location` when installing the distro,** or the disk image lands on `C:`.

## Open questions

- Does the unsigned `.app` sign and install? Needs a device. Next spike.
- What to put in the build metadata keys for App Store upload.
- Whether xtool's full SDK is needed, or the slim variant is enough, for our pipeline.

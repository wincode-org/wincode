# 0001. Run the build toolchain in WSL2

- Status: Accepted
- Date: 2026-10-16 (proposed 2026-10-12)

## Context

Compiling the iOS runner and plugins needs Swift, LLVM and the Darwin Swift SDK that xtool builds from the user's own Xcode.xip. xtool runs on Linux, WSL and macOS, not natively on Windows. The Dart-side steps (`frontend_server`, assets, `flutter attach`) already run on Windows. See docs/PLAN.md, "Architecture".

Phase 0 confirmed this setup:

- **Day-2 spike:** built an xtool app in WSL2 Ubuntu 24.04 with Swift 6.4 and a Darwin SDK built from Xcode 26.6.
- **Spike A:** built `gen_snapshot` for iOS in WSL2 (ADR-0004).
- **Spike B:** built, signed and installed a Flutter app from WSL2 onto an iPhone.

The spike records are in `docs/spikes/`.

## Decision

- **Windows hosts** the CLI, the GUI, the Flutter SDK and the App Store client.
- **A Linux toolchain inside WSL2, driven by the CLI, runs** the compile and link steps (Swift, LLVM, `gen_snapshot` for iOS) and provisioning and signing (xtool, which uses zsign).
- **Device traffic goes through Apple's device service on Windows** (ADR-0005).
- **The toolchain never contains Apple SDK files.** The Darwin SDK is built on the user's machine from their own Xcode.xip.

## Consequences

- winCode reuses xtool and zsign as they are, with no Windows port needed.
- **Users need WSL2.** It must run in mirrored networking mode for the device link (ADR-0005), and `wincode setup` must install and verify both.
- **Files cross the Windows/WSL boundary.** Path handling and build speed need care: work in the WSL filesystem.
- **Disk use:** the Darwin SDK takes about 8 GB inside WSL.
- A native Windows toolchain can be revisited later.

## Alternatives considered

- **A native Windows Swift toolchain:** xtool does not support it, and it would be much more work.
- **Remote Mac builds:** defeat the purpose of winCode. Kept only as the optional release lane.
- **Docker:** heavier for users than WSL2, which Windows 11 already includes.

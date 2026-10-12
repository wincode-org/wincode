# 0001. Run the build toolchain in WSL2

- Status: Proposed
- Date: 2026-10-12

## Context

Compiling the iOS runner and plugins needs Swift, LLVM and the Darwin Swift SDK that xtool builds from the user's own Xcode.xip. xtool runs on Linux, WSL and macOS, not natively on Windows. The Dart-side steps (`frontend_server`, assets, `flutter attach`) already run on Windows. See docs/PLAN.md, "Architecture".

## Decision

Windows hosts the CLI, GUI, Flutter SDK, device bridge and App Store client. The compile and link steps (Swift, LLVM, zsign, `gen_snapshot` for iOS) run in a Linux toolchain inside WSL2, driven by the CLI. The toolchain never contains Apple SDK files; the Darwin SDK is built on the user's machine from their own Xcode.xip.

## Consequences

- Reuses xtool and zsign as they are, with no Windows port needed.
- Users need WSL2 enabled; `wincode setup` must install and verify it.
- Files cross the Windows/WSL boundary, so path handling and build speed (work in the WSL filesystem) need care.
- A native Windows toolchain can be revisited later.

## Alternatives considered

- Native Windows Swift toolchain: xtool does not support it, and much more work.
- Remote Mac build: defeats the goal, kept only as the optional release lane.
- Docker: heavier for users than WSL2, which Windows 11 already includes.

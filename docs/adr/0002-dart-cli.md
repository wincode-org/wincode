# 0002. Write the CLI in Dart

- Status: Proposed
- Date: 2026-10-12

## Context

winCode orchestrates the Flutter toolchain, WSL2, the device bridge and the App Store Connect API. The users and the contributors we expect are Flutter developers, and Studio (the GUI) is a Flutter app. See docs/PLAN.md, "Architecture" and "Open-source setup".

## Decision

`wincode` is a Dart CLI (`packages/wincode_cli`). Shared logic lives in Dart packages (`wincode_core`, `wincode_asc`) that both the CLI and Studio use. The Swift-side work runs in WSL2 as external processes, not as Dart code.

## Consequences

- One language across CLI and GUI, and a low barrier for Flutter contributors.
- Dart ships with the Flutter SDK users already have, and compiles to a standalone Windows executable.
- Swift code (XKit) cannot be imported; we call xtool as a process or reimplement what we need.
- GPL-licensed tools such as pymobiledevice3 are only ever run as separate processes, never imported, to keep the repo MIT.

## Alternatives considered

- Swift CLI: matches xtool, but a poor fit for Windows and for Flutter contributors.
- Rust or Go: good for single binaries, but split the codebase from Studio.
- Python: easy to reach pymobiledevice3, but harder to ship and a GPL boundary risk.

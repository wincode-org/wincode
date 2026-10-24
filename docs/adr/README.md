# adr

Architecture Decision Records. Copy `0000-template.md` for each new decision.

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](0001-wsl2-toolchain.md) | Run the build toolchain in WSL2 | Accepted |
| [0002](0002-dart-cli.md) | Write the CLI in Dart | Proposed |
| [0003](0003-swiftpm-only-plugins-v1.md) | Support only Swift Package Manager plugins in v1 | Proposed |
| [0004](0004-gen-snapshot-on-linux.md) | Build the iOS gen_snapshot on Linux from the Dart SDK | Accepted |
| [0005](0005-device-link-apple-device-service.md) | Reach the iPhone through Apple's Windows device service | Accepted |
| [0006](0006-keep-code-in-wincode.md) | Keep all of winCode's code in the winCode repository | Accepted |
| [0007](0007-vendor-xtool-source.md) | Keep a copy of xtool's source in third_party/xtool | Accepted |
| [0008](0008-two-release-lanes.md) | Two release lanes: pure Windows and cloud Mac | Proposed |
| [0009](0009-store-signing-in-wincode.md) | winCode owns store signing and never revokes certificates on its own | Proposed |
| [0010](0010-native-build-hooks.md) | Run Dart build hooks ourselves, with an xcrun shim for the Darwin SDK | Proposed |
| [0011](0011-store-bundle-rules.md) | Store bundle rules: what a Windows-built store bundle matches in Xcode's, and what it never fakes | Proposed |

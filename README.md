# winCode

Build, run and ship Flutter iOS apps from Windows.

**Status: pre-alpha.** There is no `wincode` command yet (`packages/wincode_cli` is a placeholder), so nothing here takes a Flutter project to an IPA in one step. The plan of record is in [docs/PLAN.md](docs/PLAN.md).

What exists today:

- **A tested Dart library,** `packages/wincode_core`: it reads an app's Xcode flavors and builds its `Info.plist` and entitlements, drives `gen_snapshot` for iOS (built on Linux) the way `flutter_tools` does, builds the Swift runner and the plugin packages, writes plugin resource bundles the way Xcode does, and makes the small Mach-O edits a release bundle needs.
- **Spikes with recorded results,** in [docs/spikes](docs/spikes): a Flutter counter app built on Windows ran on an iPhone (spike B), and a build signed and uploaded from Windows was processed as valid by App Store Connect (spike C, with an `Assets.car` made by Xcode on a Mac).
- **What is missing:** winCode cannot compile asset catalogs (`Assets.car`) yet, packages that ship their own compiled catalogs still need a Mac build, and there is no hot reload, debugging or GUI.

The history in this repository was imported from an earlier private repository: pull request numbers in older merge-commit messages (for example "Merge pull request #37") refer to that private archive, not to this repository.

## What it will do

winCode is a Dart CLI and a Flutter GUI (winCode Studio) that take a Flutter project on Windows to a signed IPA, onto a real iPhone, and up to App Store Connect. The compile step runs in a Linux toolchain inside WSL2. The iPhone and Apple's servers are reached from the Windows side.

It will not ship an iOS Simulator. Instead there is a planned iOS-mode preview on Windows, plus running on your real iPhone.

## Relationship to xtool

winCode builds on [xtool](https://github.com/xtool-org/xtool) (MIT) instead of reimplementing it. xtool provides the Darwin Swift SDK setup, Apple Developer Services access (XKit) and signing/install for SwiftPM apps. winCode adds everything else: the Flutter project translator, Dart AOT `gen_snapshot` for iOS, the Windows setup and device link, asset catalog compilation, and App Store Connect upload. All of winCode's code lives in this repository. winCode uses xtool's official releases as an external tool and does not send changes upstream to xtool.

## Repository layout

| Path | Contents |
| --- | --- |
| `packages/wincode_cli` | Dart CLI |
| `packages/wincode_core` | Project translator, plist, IPA packaging |
| `packages/wincode_asc` | App Store Connect API client |
| `apps/wincode_studio` | Flutter Windows GUI |
| `toolchain` | WSL2 toolchain (Swift, xtool, LLVM, zsign) |
| `engine` | `gen_snapshot`-for-iOS build scripts |
| `docs` | ADRs and format specs |
| `samples` | Sample Flutter apps |

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Governance is described in [GOVERNANCE.md](GOVERNANCE.md).

## Legal

- You download `Xcode.xip` from Apple yourself and accept Apple's licence yourself. winCode never ships, hosts or redistributes Apple SDK files, Xcode binaries, fonts or simulator runtimes.
- winCode is not affiliated with, endorsed by, or sponsored by Apple Inc. Apple, Xcode, iOS, iPhone, App Store and TestFlight are trademarks of Apple Inc.
- Apple's terms restrict where its SDKs may be used. Whether your use of winCode complies with them is your responsibility.
- Apple can suspend or terminate developer accounts. Any Apple account you use with winCode is at your own risk.
- This is not legal advice.

## Licence

[MIT](LICENSE)

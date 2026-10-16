# winCode — Build Flutter iOS apps on Windows

Status: APPROVED by Alpha on 2026-10-12. This is the plan of record. Updated 2026-10-16 with the phase 0 results.

## Phase 0 results (2026-10-16)

**Gate G0 is met:** a Flutter counter app built from Windows (WSL2) runs on an iPhone 15 with iOS 27.0.1.

- **Spike A** (`docs/spikes/spike-a-gen-snapshot.md`):
  - A `gen_snapshot` for iOS arm64, built on Linux from the standalone Dart SDK, produces an `App.framework/App` that matches the official macOS output (ADR-0004).
  - The first kill switch is retired.
- **Spike B** (`docs/spikes/spike-b-device.md`):
  - That `App.framework` runs on the iPhone with Google's prebuilt `Flutter.framework`, in a SwiftUI runner that xtool built, signed and installed from WSL2.
  - The device link is Apple's Windows device service, not usbipd (ADR-0005).
- **What changed in this plan:**
  - Dart's Mach-O dylib output replaces the assembly + `clang` path.
  - `App.framework` is embedded, not linked.
  - Apple ID login needs xtool 1.22.2 or later.
  - The device link and launch notes are updated.

## Working agreement (how we build it)

- Two lanes:
  - Web / account / browser tasks (GitHub org + repo settings, Apple Developer, App Store Connect, research): the chat assistant does them directly.
  - Coding / file creation / running commands: the chat assistant writes a prompt, Alpha pastes it into the coding assistant, the coding assistant does the work, Alpha pastes back the result or errors.
- The coding assistant is opened in the winCode repo folder (not inside the xtool clone). The xtool clone sits next to it as read-only reference, added with `--add-dir`.
- Real REA (morluto/rea, `npx rea-agents setup`) is installed in the coding assistant. Never use the fake `rea-tools/rea` repo or its `rea.exe`.
- Every change goes through a PR on GitHub, even solo: Conventional Commits, DCO sign-off, green CI.

## Verdict: buildable, except the simulator

winCode can realistically take a Flutter app from Windows to a signed IPA, onto a real iPhone, and up to App Store Connect. It cannot ship an iOS Simulator on Windows, and App Store acceptance of a non-Xcode build is still unproven.

| Feature | Feasible? | How winCode does it | Main blocker |
| --- | --- | --- | --- |
| Build an IPA on Windows | Yes, proven in phase 0 | Linux toolchain in WSL2, Darwin SDK from the user's own Xcode.xip (the xtool approach), `gen_snapshot` for iOS built on Linux (ADR-0004) | Solved for the compile step; store builds still need `Assets.car` (below) |
| Install and run on a real iPhone | Yes, proven on iOS 27.0.1 | xtool (XKit, zsign) in WSL2, through Apple's Windows device service (ADR-0005) | No launch from Linux yet: the app is opened by hand. The first launch needs the developer profile trusted and Developer Mode on |
| Debug mode and hot reload on iPhone | Yes, the hardest part | debugserver over the iOS 17 tunnel + LLDB + `flutter attach` | iOS 26 blocks Dart's JIT unless a debugger manages memory |
| iOS Simulator on Windows | No | Replaced by an iOS-mode preview on Windows + the real device | The Simulator is macOS-only; QEMU iOS emulation is research-grade |
| Upload to App Store Connect | Yes | App Store Connect API build uploads, no Xcode | None technical |
| Pass Apple's upload validation and review | Unproven | Own `Assets.car` compiler, correct build keys in Info.plist | Asset catalog format is undocumented; Xcode 26 / iOS 26 SDK rule |
| Every Flutter plugin | Partial | Swift Package Manager plugins only in v1 | CocoaPods-only plugins need conversion |

Recommended v1 scope: Flutter apps whose plugins support Swift Package Manager (the default since Flutter 3.44), iPhones on iOS 17.4 or later, release and profile builds first, hot reload second.

Positioning: don't sell it as an "Xcode replacement" or use Apple marks in the name or logo. Sell it as "Flutter iOS without a Mac: build, run on your iPhone, ship to TestFlight".

## Build on xtool, don't clone it

xtool already solves half of winCode and is MIT-licensed, so winCode uses it as a tool instead of reverse engineering it. All of winCode's own code, Flutter-specific or not, lives in the winCode repo; winCode does not send changes upstream to xtool (ADR-0006).

How xtool works: setup asks you to supply Xcode.xip yourself and builds a Darwin Swift SDK from it on your machine. It then compiles with `swift build --swift-sdk arm64-apple-ios`, signs, installs on a device, and talks to Apple Developer Services through its `XKit` library. It runs on Linux, WSL and macOS.

What xtool does not do, per its author: Interface Builder (storyboards), asset catalogs ("require reverse engineering"), Apple-only macros, LLDB debugging on iOS 17+, and App Store Connect deployment. It builds only SwiftPM packages, not Xcode projects, and knows nothing about Dart, `App.framework` or `Flutter.framework`.

| Need | Reuse | Build new in winCode |
| --- | --- | --- |
| Darwin SDK from Xcode.xip | `xtool sdk` | Windows setup wizard around it |
| Compile runner + plugins | xtool's Swift SDK | Translator: `ios/Runner` + Flutter's SwiftPM plugin package into one SwiftPM package |
| Apple account, certificates, App IDs, profiles | XKit | GUI flows |
| Code signing | zsign (xtool bundles it) | Entitlements merge |
| Install and launch on iPhone | XKit for install (spike B); pymobiledevice3 for launch and debugging | Device link setup through Apple's Windows device service (ADR-0005) |
| Dart AOT for iOS | Nothing | `gen_snapshot` built on Linux per Flutter release (ADR-0004, proven in spike A) |
| App icon in `Assets.car` | Nothing | Clean-room compiler |
| LLDB on iOS 17+ | pymobiledevice3 | Integration |
| App Store upload | Nothing | App Store Connect API client |

## Architecture

winCode is a Dart CLI and a Flutter GUI on Windows that drive a Linux toolchain in WSL2. The iPhone is reached through Apple's device service on Windows (ADR-0005). Provisioning and signing run in WSL2 through xtool.

- **Windows host:**
  - winCode Studio (Flutter GUI) → wincode CLI (Dart, orchestrates everything)
  - Flutter SDK for Windows (frontend_server → app.dill, assets, flutter attach)
  - iOS preview (desktop runner in iOS mode + device frames)
  - Device link: Apple Devices' device service on `127.0.0.1:27015`, used from WSL2 through mirrored networking (ADR-0005); pymobiledevice3 for launch and debugserver (phase 3)
  - App Store client (API key: certs, profiles, build uploads)
- **WSL2 toolchain (Linux):**
  - Darwin Swift SDK (built from the user's Xcode.xip, never shipped)
  - gen_snapshot for iOS (Dart AOT → iOS arm64, built by winCode CI per Flutter release, ADR-0004)
  - Swift + LLVM via xtool (compiles runner and plugins, links Mach-O)
  - Resources + xtool signing with zsign (Info.plist, Assets.car, provisioning, the .ipa)
- **Outside the PC:**
  - iPhone (USB, iOS 17.4+, Developer Mode)
  - App Store Connect (TestFlight, review)
  - optional macOS CI (Mac release lane + Xcode oracle tests)

The two pieces no open-source project provides yet: `gen_snapshot` for iOS on a non-Mac host (done in phase 0, ADR-0004) and an `Assets.car` compiler (phase 4).

## Build pipeline: Dart source to signed IPA

1. Read the project: `pubspec.yaml`, `ios/Runner/Info.plist`, entitlements, `AppDelegate.swift`, flavors. Stop with a clear message if a plugin is CocoaPods-only.
2. Dart to kernel: Flutter's `frontend_server` in AOT mode → `app.dill`; build `flutter_assets`. Both already run on Windows.
3. Kernel to iOS machine code (ADR-0004):
   - **Tool:** winCode's Linux-built `gen_snapshot` for the user's Flutter version. winCode CI builds and publishes it per Flutter release from the `dart_revision` that release pins.
   - **Arguments:** exactly flutter_tools' iOS release arguments, `--snapshot_kind=app-aot-macho-dylib` and the `--macho*` flags.
   - **Output:** gen_snapshot writes the Mach-O `App.framework/App` directly, with the iOS build version, install name, rpaths, compact unwind info and an ad-hoc signature.
   - **Then:** `dsymutil` for the dSYM and `strip -x`. Add `Info.plist` (`io.flutter.flutter.app`, `MinimumOSVersion`) and `flutter_assets` to make `App.framework`.
   - The assembly + `clang` path is not used.
4. Engine: download `Flutter.xcframework` for that engine hash, take the `ios-arm64` slice.
5. Native code: generate one SwiftPM package (Runner + Flutter's generated plugin package + Flutter binary target), `swift build --swift-sdk arm64-apple-ios -c release` in WSL2.
   - Spike B confirmed that `Flutter.xcframework` works as a SwiftPM binary target with xtool.
   - Use the release configuration: debug builds embed build-machine paths in the binary's rpaths.
6. Resources: merge Info.plist; replace storyboards with `UILaunchScreen` + code-created `FlutterViewController` (no `ibtool`); compile the app icon into `Assets.car` + `CFBundleIconName`; copy `PrivacyInfo.xcprivacy` files.
7. Bundle: `Runner.app` with `Frameworks/App.framework`, `Frameworks/Flutter.framework`, plugin frameworks, `embedded.mobileprovision`.
   - `App.framework` is copied in, not linked. Dart's Mach-O has no exports trie, so the linker refuses it, and the engine loads it at runtime anyway (spike B).
8. Provision and sign inside-out (xtool with zsign, merged entitlements), zip `Payload/` → `.ipa`.

Debug builds skip step 3 (kernel blob + engine JIT snapshots) and run only with a debugger attached. Every release is checked by an "oracle" CI job: the same sample built with real Xcode on a macOS runner, bundles diffed. For `gen_snapshot` the oracle already exists: `.github/workflows/spike-a-oracle.yml`.

## Real iPhone: install, logs, hot reload

- Connection (ADR-0005):
  - Apple's device service from the Apple Devices app, reached from WSL2 in mirrored networking mode at `127.0.0.1:27015`.
  - usbipd is not supported: it corrupts large USB transfers.
  - From iOS 17.4 the lockdown tunnel reaches developer services on every platform.
  - Developer Mode must be on. The first launch of a development-signed app needs the developer profile trusted in Settings.
- Release/profile loop (phase 1): build, sign with development profile, install, launch, stream device log. No debugger needed.
  - Spike B proved every step except launch.
  - xtool cannot mount the developer disk image on Linux, so the app is opened by hand until winCode has a launch path. pymobiledevice3 on Windows is the candidate.
- Debug loop with hot reload (phase 3), copying Flutter 3.38+ on Mac:
  1. Build debug (JIT).
  2. Install, launch stopped through `debugserver` over the iOS 17 tunnel.
  3. Attach LLVM `lldb` and load Flutter's LLDB helper (breakpoint on `NOTIFY_DEBUGGER_ABOUT_RX_PAGES`). Since iOS 26 a debug build without a debugger crashes at launch.
  4. Forward the Dart VM service port; `flutter attach --debug-url` from Windows → hot reload, DevTools.
- Support floor v1: Flutter 3.38+, iOS 17.4+, USB first.

## No simulator: preview on Windows plus the real iPhone

- Why not emulate: QEMU iOS projects boot iOS 3.1.3 or partial iOS 14 with patched kernels; research only, and breaks Apple's licence.
- `wincode preview`: Windows desktop Flutter app with target platform forced to iOS; iPhone frames, safe areas, Cupertino widgets, mock plugin channels with "mocked" badges, licence-safe font substitute, desktop hot reload. Cannot show native plugin behaviour, platform views, real performance.
- Device mirror: optional low-fps screenshot stream from the iPhone.
- Remote Mac Simulator: plugin, not in v1.

## Signing and App Store submission

- Free Apple ID: development signing, short-lived profiles.
  - Apple ID login needs xtool 1.22.2 or later; 1.21.0 hit Apple's `-80045`.
  - Accounts with only SMS two-factor authentication currently fail (xtool-org/xtool#345).
- Paid account: App Store Connect API key (.p8); winCode makes CSR (OpenSSL), distribution cert, App ID, profile via API; secrets in Windows Credential Manager.
- Signing: zsign (native Windows/Linux, MIT), through xtool in v1.
- Upload: App Store Connect API Build uploads (create, reserve, send, commit; webhook for status). Transporter CLI as backup.

| Gate | Apple's rule | winCode's answer |
| --- | --- | --- |
| SDK version | Since April 28, 2026: Xcode 26+ / iOS 26 SDK | Require the user's Xcode 26.x xip |
| Minimum iOS | Since September 9, 2026: target iOS 13+ | Default iOS 14 (Info.plist launch screen) |
| App icon | Asset catalog + `CFBundleIconName` (ITMS-90713) | Own `Assets.car` compiler |
| Privacy manifest | Approved reasons for required-reason APIs | Merge `PrivacyInfo.xcprivacy` |
| Build metadata | Xcode writes SDK/toolchain keys | Only true values from the user's Xcode.xip; never fake a Mac build machine |

Fallback: Mac release lane — generated GitHub Actions workflow builds the final App Store binary on a macOS runner. Default for production until several winCode-built apps are accepted.

## Reverse engineering scope and the legal line

- Use the real REA (morluto/rea). `rea-tools/rea` is an impersonation/malware repo.
- REA only for file formats and outputs (compiled `Assets.car`, Xcode-written Info.plist keys, `.ipa` layout). Never decompile Apple tools (`actool`, `ibtool`, CoreUI).
- Clean room for `Assets.car`: A builds samples with real Xcode on Apple hardware (macOS CI) and writes a spec in `docs/formats/`; B implements from the spec only; PRs record provenance.
- Apple terms forbid running Apple SDKs on non-Apple-branded computers and reverse engineering Apple software. xtool model: ship no SDK bits; users download Xcode.xip and accept the licence themselves. winCode does the same and says so in README and `wincode setup`.
- Never redistribute SDK headers/libs, Xcode binaries, Apple fonts, simulator runtimes (incl. public CI caches).
- Apple can terminate developer accounts; README states the risk.
- No Apple logos; no "Xcode for Windows" tagline.
- Dependency licences: pymobiledevice3 is GPL-3.0 → separate process the user installs, never imported into MIT code. zsign and xtool MIT, Flutter engine BSD.
- Not legal advice; lawyer review before marketing App Store submission from Windows.

## Roadmap (rough, one part-time maintainer)

| Phase | Duration | Deliverables | Gate |
| --- | --- | --- | --- |
| 0 Foundations | 2 weeks | Repo + governance, xtool in WSL2, gen_snapshot spike, hand-assembled counter app | G0: counter app built on Windows runs on the iPhone (met 2026-10-16) |
| 1 Release builds | 6–8 weeks | `wincode build ipa / install / run`, SwiftPM plugins, translator, signing, device logs | G1: 5 sample apps with common plugins run on device |
| 2 Preview + Studio | 4 weeks | iOS-mode preview, device mirror, Studio GUI, alpha v0.1 | G2: alpha v0.1 installable by outsiders |
| 3 Debug + hot reload | 6–8 weeks | debugserver + LLDB helper, flutter attach, DevTools | G3: hot reload on an iOS 26 iPhone over USB |
| 4 Ship to Apple | 6–10 weeks | Assets.car compiler, certs/profiles via API, build upload, Mac lane fallback | G4 (key gate): one real app accepted on TestFlight and the App Store |
| 5 v1.0 hardening | ongoing | Installer, docs site, Flutter stable+beta CI, iOS 27, more plugins, co-maintainers | — |

G0 was met on 2026-10-16, so the first kill switch below is retired.

## Open-source setup: repo, PRs, CI

Monorepo:

```
wincode/
  packages/wincode_cli/     Dart CLI: commands, orchestration
  packages/wincode_core/    Dart: project translator, plist, ipa
  packages/wincode_asc/     Dart: App Store Connect API client
  apps/wincode_studio/      Flutter Windows GUI
  toolchain/                WSL2 image: Swift, xtool, LLVM, zsign
  engine/                   gen_snapshot-for-iOS build scripts per Flutter release
  docs/                     site, adr/, formats/
  samples/                  counter, plugins_demo, flavors_demo
  .github/                  workflows, templates, CODEOWNERS
```

- Root files: LICENSE (MIT), README (scope + licence notice), CONTRIBUTING, CODE_OF_CONDUCT (Contributor Covenant), SECURITY, GOVERNANCE, docs/adr/.
- PR workflow: Conventional Commits (title check action), DCO sign-off, PR template (what/why, issue, test evidence, device + iOS version, Apple-format provenance box), protected main (1 review, green CI, linear history; branch protection needs GitHub Pro or a public repo, so until then main is protected by convention: PRs only), CODEOWNERS, labels `area/*`, `good first issue`, `needs-device-test`, release-please, signed Windows installer later winget.
- CI (licence-clean): lint+unit on Ubuntu+Windows; end-to-end build and Xcode oracle diff on macOS runners; GUI/device bridge with mocks on Windows; nightly hardware-in-the-loop on self-hosted Windows PC + iPhone.
- Community: Discussions, GitHub Projects roadmap, monthly release, `help wanted` for Assets.car and LLDB.

## Risks and kill switches

| Risk | Mitigation | Kill switch / pivot |
| --- | --- | --- |
| `gen_snapshot` for iOS can't be built for Linux/Windows host | Retired 2026-10-16: built on Linux and matched against the Mac output (ADR-0004) | — |
| Dart changes break the Linux `gen_snapshot` build | Anchored GN edits fail loudly; per-release CI with the hash, features and oracle checks (ADR-0004) | Hold that Flutter release until the build is fixed |
| Apple breaks Apple ID login for third-party tools (it did: `-80045`, fixed in xtool 1.22.2 within days) | Track xtool releases; recommend API key login for paid accounts | API key login only |
| The device link breaks (Apple Devices or WSL networking changes) | `wincode setup` checks it (ADR-0005); NAT + port proxy as fallback | Install from Windows with pymobiledevice3 |
| Apple rejects non-Xcode builds | Gates table; oracle diffs | Mac release lane stays production default |
| `Assets.car` too hard | Clean-room spec in `docs/formats/` | Mac lane for store builds only |
| Licence enforcement / bans / takedowns | No SDK redistribution; BYO Xcode.xip; lawyer review | Drop App Store upload from Windows |
| Flutter iOS internals change each release | Support latest two stables; CI on stable + beta | — |
| New iOS breaks device protocols | Lean on pymobiledevice3/xtool upstream | — |
| Solo burnout | Narrow v1; two co-maintainers by v0.1; Sponsors | — |

## First two weeks

- [x] Day 1: remove fake `rea.exe`, install real REA (`npx rea-agents setup`).
- [x] Day 1: create org + repo with licence, README, CONTRIBUTING, CoC, SECURITY, PR/issue templates. Branch protection is not available for a private repo on the free plan.
- [x] Day 2: xtool in WSL2 Ubuntu, Xcode 26.x xip from Apple, build xtool hello-world (`docs/spikes/day2-xtool-setup.md`). The first iPhone install happened in spike B.
- [x] Days 3–5, spike A: build `gen_snapshot` (Flutter 3.47 engine revision) Linux host → iOS arm64; compile counter `app.dill`; compare with macOS `gen_snapshot` on a GitHub macOS runner (`docs/spikes/spike-a-gen-snapshot.md`).
- [x] Days 6–8, spike B: hand-assemble `Runner.app` (SwiftPM runner + Flutter.framework + App.framework), sign with zsign through xtool, install with xtool, counter app runs (`docs/spikes/spike-b-device.md`).
- [x] Week 2: ADRs. ADR-0001 (WSL2 toolchain) is accepted; ADR-0002 (Dart CLI) and ADR-0003 (SwiftPM-only plugins in v1) stay proposed; ADR-0004 (gen_snapshot on Linux) and ADR-0005 (device link) were added.
- [ ] Week 2: open phase 1 issues.
- [ ] Week 2: post spike result publicly.
- [x] Gate G0 (2026-10-16).

Once phase 1 ships, SPC Studio's iOS option can call `wincode build ipa` instead of generating a prompt for a Mac.

## Sources

- xtool: https://github.com/xtool-org/xtool · announcement: https://forums.swift.org/t/xtool-cross-platform-xcode-replacement-build-ios-apps-on-linux-and-more/79803
- REA official: https://github.com/morluto/rea (avoid https://github.com/rea-tools/rea)
- Apple upcoming requirements: https://developer.apple.com/news/upcoming-requirements/
- ASC API build uploads: https://developer.apple.com/documentation/appstoreconnectapi/build-uploads
- Flutter SwiftPM: https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers
- Dart app-aot-macho-dylib commit: https://dart.googlesource.com/sdk/+/38ef28a0589c0ac3009856a636b353e419e25c46%5E%21
- Flutter iOS 26 debug + LLDB: https://startdebugging.net/2026/08/fix-mprotect-failed-permission-denied-in-a-flutter-ios-debug-build/
- pymobiledevice3: https://github.com/doronz88/pymobiledevice3 · zsign: https://github.com/zhlynn/zsign
- xtool login fix (`-80045`): https://github.com/xtool-org/xtool/issues/329 · xtool device link on WSL: https://github.com/xtool-org/xtool/issues/19 · usbipd-win: https://github.com/dorssel/usbipd-win/issues/959

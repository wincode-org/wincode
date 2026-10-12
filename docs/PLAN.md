# winCode — Build Flutter iOS apps on Windows

Status: APPROVED by Alpha on 2026-10-12. This is the plan of record.

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
| Build an IPA on Windows | Yes, hard | Linux toolchain in WSL2, Darwin SDK from the user's own Xcode.xip (the xtool approach), cross-built `gen_snapshot` | Flutter ships the iOS `gen_snapshot` only as a macOS binary |
| Install and run on a real iPhone | Yes | xtool's XKit or pymobiledevice3, signing with zsign | iOS 17+ CoreDevice tunnels; Windows needs Apple's device driver |
| Debug mode and hot reload on iPhone | Yes, the hardest part | debugserver over the iOS 17 tunnel + LLDB + `flutter attach` | iOS 26 blocks Dart's JIT unless a debugger manages memory |
| iOS Simulator on Windows | No | Replaced by an iOS-mode preview on Windows + the real device | The Simulator is macOS-only; QEMU iOS emulation is research-grade |
| Upload to App Store Connect | Yes | App Store Connect API build uploads, no Xcode | None technical |
| Pass Apple's upload validation and review | Unproven | Own `Assets.car` compiler, correct build keys in Info.plist | Asset catalog format is undocumented; Xcode 26 / iOS 26 SDK rule |
| Every Flutter plugin | Partial | Swift Package Manager plugins only in v1 | CocoaPods-only plugins need conversion |

Recommended v1 scope: Flutter apps whose plugins support Swift Package Manager (the default since Flutter 3.44), iPhones on iOS 17.4 or later, release and profile builds first, hot reload second.

Positioning: don't sell it as an "Xcode replacement" or use Apple marks in the name or logo. Sell it as "Flutter iOS without a Mac: build, run on your iPhone, ship to TestFlight".

## Build on xtool, don't clone it

xtool already solves half of winCode and is MIT-licensed, so winCode builds on top of it instead of reverse engineering it. Anything that is not Flutter-specific goes upstream to xtool as a PR.

How xtool works: setup asks you to supply Xcode.xip yourself and builds a Darwin Swift SDK from it on your machine. It then compiles with `swift build --swift-sdk arm64-apple-ios`, signs, installs on a device, and talks to Apple Developer Services through its `XKit` library. It runs on Linux, WSL and macOS.

What xtool does not do, per its author: Interface Builder (storyboards), asset catalogs ("require reverse engineering"), Apple-only macros, LLDB debugging on iOS 17+, and App Store Connect deployment. It builds only SwiftPM packages, not Xcode projects, and knows nothing about Dart, `App.framework` or `Flutter.framework`.

| Need | Reuse | Build new in winCode | Upstream to xtool? |
| --- | --- | --- | --- |
| Darwin SDK from Xcode.xip | `xtool sdk` | Windows setup wizard around it | No |
| Compile runner + plugins | xtool's Swift SDK | Translator: `ios/Runner` + Flutter's SwiftPM plugin package into one SwiftPM package | No |
| Apple account, certificates, App IDs, profiles | XKit | GUI flows | No |
| Code signing | zsign (xtool bundles it) | Entitlements merge | No |
| Install and launch on iPhone | XKit or pymobiledevice3 | Windows device bridge | No |
| Dart AOT for iOS | Nothing | `gen_snapshot` built for a Linux/Windows host | No (Flutter-specific) |
| App icon in `Assets.car` | Nothing | Clean-room compiler | Yes |
| LLDB on iOS 17+ | pymobiledevice3 | Integration | Yes |
| App Store upload | Nothing | App Store Connect API client | Yes |

## Architecture

winCode is a Dart CLI and a Flutter GUI on Windows that drive a Linux toolchain in WSL2; the iPhone and Apple's servers are reached only from the Windows side.

- Windows host: winCode Studio (Flutter GUI) → wincode CLI (Dart, orchestrates everything) · Flutter SDK for Windows (frontend_server → app.dill, assets, flutter attach) · iOS preview (desktop runner in iOS mode + device frames) · Device bridge (pymobiledevice3: install, logs, debugserver) · App Store client (API key: certs, profiles, build uploads)
- WSL2 toolchain (Linux): Darwin Swift SDK (built from the user's Xcode.xip, never shipped) · gen_snapshot for iOS (NEW: Dart AOT → iOS arm64, per Flutter version) · Swift + LLVM via xtool (compiles runner and plugins, links Mach-O) · Resources + zsign (Info.plist, Assets.car, signing, the .ipa)
- Outside the PC: iPhone (USB, iOS 17.4+, Developer Mode) · App Store Connect (TestFlight, review) · optional macOS CI (Mac release lane + Xcode oracle tests)

The two pieces no open-source project provides yet: `gen_snapshot` for iOS on a non-Mac host, and an `Assets.car` compiler.

## Build pipeline: Dart source to signed IPA

1. Read the project: `pubspec.yaml`, `ios/Runner/Info.plist`, entitlements, `AppDelegate.swift`, flavors. Stop with a clear message if a plugin is CocoaPods-only.
2. Dart to kernel: Flutter's `frontend_server` in AOT mode → `app.dill`; build `flutter_assets`. Both already run on Windows.
3. Kernel to iOS machine code: `gen_snapshot` built for a Linux (later Windows) host targeting iOS arm64, from the exact engine revision of the user's Flutter version. winCode CI builds and publishes it per Flutter release.
   - Path A (start here): assembly → `clang` for `arm64-apple-ios`.
   - Path B: `--snapshot_kind=app-aot-macho-dylib` (added to Dart May 2025; no compact unwind info yet).
   - Wrap as `App.framework`.
4. Engine: download `Flutter.xcframework` for that engine hash, take the `ios-arm64` slice.
5. Native code: generate one SwiftPM package (Runner + Flutter's generated plugin package + Flutter binary target), `swift build --swift-sdk arm64-apple-ios -c release` in WSL2.
6. Resources: merge Info.plist; replace storyboards with `UILaunchScreen` + code-created `FlutterViewController` (no `ibtool`); compile the app icon into `Assets.car` + `CFBundleIconName`; copy `PrivacyInfo.xcprivacy` files.
7. Bundle: `Runner.app` with `Frameworks/App.framework`, `Frameworks/Flutter.framework`, plugin frameworks, `embedded.mobileprovision`.
8. Sign inside-out with zsign + merged entitlements, zip `Payload/` → `.ipa`.

Debug builds skip step 3 (kernel blob + engine JIT snapshots) and run only with a debugger attached. Every release is checked by an "oracle" CI job: the same sample built with real Xcode on a macOS runner, bundles diffed.

## Real iPhone: install, logs, hot reload

- Connection on Windows: Apple's device driver (Apple Devices app or iTunes) provides USB; pymobiledevice3 needs it. From iOS 17.4 the lockdown tunnel reaches developer services on every platform. Developer Mode on.
- Release/profile loop (phase 1): build, sign with development profile, install, launch, stream device log. No debugger needed.
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
- Paid account: App Store Connect API key (.p8); winCode makes CSR (OpenSSL), distribution cert, App ID, profile via API; secrets in Windows Credential Manager.
- Signing: zsign (native Windows/Linux, MIT).
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
| 0 Foundations | 2 weeks | Repo + governance, xtool in WSL2, gen_snapshot spike, hand-assembled counter app | G0: counter app built on Windows runs on the iPhone |
| 1 Release builds | 6–8 weeks | `wincode build ipa / install / run`, SwiftPM plugins, translator, signing, device logs | G1: 5 sample apps with common plugins run on device |
| 2 Preview + Studio | 4 weeks | iOS-mode preview, device mirror, Studio GUI, alpha v0.1 | G2: alpha v0.1 installable by outsiders |
| 3 Debug + hot reload | 6–8 weeks | debugserver + LLDB helper, flutter attach, DevTools | G3: hot reload on an iOS 26 iPhone over USB |
| 4 Ship to Apple | 6–10 weeks | Assets.car compiler, certs/profiles via API, build upload, Mac lane fallback | G4 (key gate): one real app accepted on TestFlight and the App Store |
| 5 v1.0 hardening | ongoing | Installer, docs site, Flutter stable+beta CI, iOS 27, more plugins, co-maintainers | — |

If G0 fails → first kill switch below.

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
- PR workflow: Conventional Commits (title check action), DCO sign-off, PR template (what/why, issue, test evidence, device + iOS version, Apple-format provenance box), protected main (1 review, green CI, linear history), CODEOWNERS, labels `area/*`, `good first issue`, `needs-device-test`, release-please, signed Windows installer later winget.
- CI (licence-clean): lint+unit on Ubuntu+Windows; end-to-end build and Xcode oracle diff on macOS runners; GUI/device bridge with mocks on Windows; nightly hardware-in-the-loop on self-hosted Windows PC + iPhone.
- Community: Discussions, GitHub Projects roadmap, monthly release, `help wanted` for Assets.car and LLDB.

## Risks and kill switches

| Risk | Mitigation | Kill switch / pivot |
| --- | --- | --- |
| `gen_snapshot` for iOS can't be built for Linux/Windows host | Spike weeks 1–3 on exact engine revision; ask Dart VM team; last resort macOS compat layer (e.g. Darling) | Fail by end of phase 0 → pivot to "Windows dev tools + remote Mac build" |
| Apple rejects non-Xcode builds | Gates table; oracle diffs | Mac release lane stays production default |
| `Assets.car` too hard | Clean-room spec; collaborate with xtool maintainer | Mac lane for store builds only |
| Licence enforcement / bans / takedowns | No SDK redistribution; BYO Xcode.xip; lawyer review | Drop App Store upload from Windows |
| Flutter iOS internals change each release | Support latest two stables; CI on stable + beta | — |
| New iOS breaks device protocols | Lean on pymobiledevice3/xtool upstream | — |
| Solo burnout | Narrow v1; two co-maintainers by v0.1; Sponsors | — |

## First two weeks

- [x] Day 1: remove fake `rea.exe`, install real REA (`npx rea-agents setup`).
- [ ] Day 1: create org + repo with licence, README, CONTRIBUTING, CoC, SECURITY, PR/issue templates, branch protection.
- [ ] Day 2: xtool in WSL2 Ubuntu, Xcode 26.x xip from Apple, build xtool hello-world, install on iPhone.
- [ ] Days 3–5, spike A: build `gen_snapshot` (Flutter 3.47 engine revision) Linux host → iOS arm64; compile counter `app.dill`; compare with macOS `gen_snapshot` on a GitHub macOS runner.
- [ ] Days 6–8, spike B: hand-assemble `Runner.app` (SwiftPM runner + Flutter.framework + App.framework), sign with zsign, install with xtool, counter app runs.
- [ ] Week 2: ADR-001 (WSL2 toolchain), ADR-002 (Dart CLI), ADR-003 (SwiftPM-only plugins in v1); open phase 1 issues.
- [ ] Week 2: post spike result publicly; contact xtool maintainer.
- [ ] Gate G0.

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

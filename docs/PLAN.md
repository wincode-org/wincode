# winCode — Build Flutter iOS apps on Windows

Status: v3, 2026-11-02. v2 was proposed on 2026-10-18, and v1 was approved by Alpha on 2026-10-12.

Gate G0 is met: a Flutter app built on Windows runs on an iPhone. Since v2, spike C has passed (App Store Connect processed a build that winCode signed and uploaded from Windows as valid), spikes D, E and F are done, and builds of real apps have reached App Store Connect through the hybrid lane: a Mac builds the unsigned IPA, and winCode signs and uploads it from Windows. What still stands between winCode and a one-command, pure-Windows store build is a short list of gaps (section "Gaps found by real apps"): winCode cannot compile asset catalogs, the Linux toolchain differs from Xcode in a few ways, and App Review has not yet judged a pure-Windows build. The `wincode` commands that work so far are `wincode doctor`, `wincode preflight` (read-only checks before an upload), `wincode init` (writes `wincode.yaml`) and `wincode sign` (zsign in WSL2, with an unencrypted key; one IPA it signed was uploaded to the test app record and processed as valid; not yet installed from TestFlight); the others are designed in ADR-0013 and say "not implemented yet", and nothing takes a project to an IPA in one step. The repository is public, as source and documentation; nothing is tagged or released yet.

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

## Where we stand

| Area | Status | Evidence |
| --- | --- | --- |
| Dart to iOS machine code on Linux | Proven | Spike A, ADR-0004 |
| Runner + Flutter.framework + App.framework | Proven | Spike B: counter app on iPhone 15, iOS 27.0.1 |
| Development signing and install | Proven | xtool 1.22.2 via Apple's device service on Windows (ADR-0005) |
| Apple ID login | Works again | xtool 1.22.2 fixed -80045; SMS-only 2FA still fails (xtool#345) |
| Launch from Windows | Open | xtool launch untested; iOS 17+ needs the personalized developer disk image |
| App Store signing | Done in scripts, not in a CLI | `spikes/c-store-acceptance` (certificate, profile, zsign), ADR-0009; xtool only makes development certificates and profiles |
| Assets.car | Not done | Two A-side observation notes exist (`docs/formats`: an app icon, and a launch colour and image, PNG only); nothing is implemented. Required by the App Store |
| Upload | Done in scripts | Build Uploads API, `spikes/c-store-acceptance/asc_upload.py`; Apple processed the builds as `VALID` |
| Apple accepting a non-Xcode build | Processing yes, App Review untested | Spike C (C1, 2026-10-23) and the builds after it; none has been through external TestFlight or App Review |
| Hybrid lane | Used for real apps | A hosted macOS runner builds the unsigned IPA with Xcode; winCode signs and uploads it from Windows (ADR-0008, ADR-0011) |
| Real-app readiness | Audited 2026-10-18, built since | The reference app (a real-world Flutter app with several native plugins, Stripe, and Google and Apple sign-in) uses only SwiftPM plugins, and its runner builds; the gaps found are in "Gaps found by real apps" and ADR-0012 |
| Native build hooks | Answered yes | Spike E (2026-10-19): the hooks run on Linux with an `xcrun` shim; ADR-0010 is still Proposed |
| The `wincode` command | Started | `wincode doctor` works (Mach-O checks); `wincode preflight` works (read-only checks of the IPA, the profile and App Store Connect, tested against a fake App Store Connect); `wincode init` works (writes `wincode.yaml` from the Xcode project and a profile folder); build, sign, upload and status are designed in ADR-0013 and say "not implemented yet"; `wincode.yaml` may describe several apps (ADR-0014): the loader reads and checks it, `preflight` and `doctor` read an app's App Store Connect key through its `credentials` reference, `--app` chooses the app of `preflight`, `doctor` and `init`, `--all` runs `preflight` and `doctor` for every app, and `init --app` adds an app to a file of apps in place, or moves a flat file under `apps:` with a backup; `packages/wincode_asc` holds the API token and the read requests |
| Debugging and hot reload | Not started | xcross is a candidate but unproven: it auto-revokes certificates and ignores flavors |
| Toolchain on this PC | Rebuilt 2026-10-18 | The WSL disk on D: vanished on 2026-10-17; Ubuntu is back on C:, rebuilt by `tools/setup-wsl-toolchain.sh` (Swift 6.4, xtool 1.22.2, Darwin SDK) and snapshotted with `wsl --export` |

Repo: the core library, the spikes through F and ADRs 0008 to 0012 are on `main` or in open pull requests; issue #7 tracks phase 1.

## What changed since v2

- **The hybrid lane exists and carries real apps.** ADR-0008's cloud Mac lane is used with winCode's own store signing and upload, so an app whose packages cannot be built on Linux yet still ships from Windows.
- **Spike C passed.** The licence review and App Review are still open, so the cloud Mac lane stays the default for store builds (ADR-0008).
- **The real-app track is the priority.** Building a real app, and a payments SDK from stock sources, showed the Linux gaps in "Gaps found by real apps". They are recorded in ADR-0012 and drive the next steps.
- **The `Assets.car` track is split in two.** Catalogs that the app owns (icon, image sets, colour sets) are the clean-room compiler's target; catalogs that third-party packages ship go through the hybrid lane for now.
- **The repository is public,** as source and documentation, and nothing is tagged or released yet. The first release (version 0.1.0) promises no command that does not exist.

## What changed in v2

1. Spike C now, not in phase 4: prove a Windows-built IPA passes App Store Connect processing and installs from TestFlight, within three weeks, alongside phase 1.
2. Shipping moves ahead of hot reload. New order: release builds → ship to Apple → preview and Studio → debugging and hot reload → hardening.
3. The Assets.car compiler starts now as a parallel track (longest task, blocks every store build).
4. Two release lanes: pure Windows (the goal) and cloud Mac (safety net). Cloud Mac is the default for store builds until spike C passes and the licence review is done.
5. Zero-rejection gate: nothing uploads unless `wincode doctor --store`, an IPA diff against an Xcode-built copy, and Apple's own validation all pass.
6. winCode owns store signing: Apple Distribution certificate + App Store profile via the App Store Connect API (xtool covers development only).
7. Launch through the user's own Xcode: the personalized developer disk image comes from the user's Xcode.xip (XcodeSystemResources_Full.pkg), never a third-party mirror; launch via pymobiledevice3 as a separate process.
8. No Simulator clone; the emulator need is met by two legal layers (below). The cloud Simulator idea is cancelled (maintainer, 2026-10-18).
9. Phase 1 grows by two items: the reference-app audit found native build hooks (a `path_provider` chain that calls `xcrun`) and Xcode flavors that winCode must handle. The hooks get a short spike E first.

## Roadmap v2 (gates renumbered)

| Phase | Length | Deliverables | Gate |
| --- | --- | --- | --- |
| 0 Foundations | done | spikes A and B | G0 met 2026-10-16 |
| 1 Release builds | 6–8 weeks | build ipa, install, run, plugins, launch | G1: 5 sample apps with plugins run on device |
| 2 Ship to Apple | 6–10 weeks | store signing, Assets.car, upload, doctor, both lanes | G2: a real app approved on the App Store (was G4) |
| 3 Preview + Studio | 4 weeks | iOS preview, device mirror, Studio, alpha v0.1 | G3: alpha installable by outsiders (was G2) |
| 4 Debug + hot reload | 6–8 weeks | debugserver, LLDB, flutter attach, DevTools | G4: hot reload on iOS 26+ (was G3) |
| 5 Hardening | ongoing | installer, docs, stable + beta CI, more plugins | — |

Parallel tracks from week 1: spike C (gate GC, weeks 1–3), cloud Mac lane v0 (weeks 1–2), Assets.car compiler (clean-room, needed for G2). Gate GC decides which lane the Ship phase builds first.

**Where each phase stands (2026-11-02).** Phase 0 is done. Phase 1 is under way as a library: the core pieces exist and are tested in CI, but the `wincode` commands that work so far are `wincode doctor`, `wincode preflight` and `wincode init`, and G1 (five sample apps with plugins running on a device) has not been run. Phase 2 has its signing and upload pieces as scripts and has passed gate GC (spike C), but not G2; `Assets.car` is not done. Phases 3 to 5 have not started. The first public release (0.1.0) is source and documentation, not one of these gates.

- **Scope of v1:** Flutter apps whose plugins support Swift Package Manager (the default since Flutter 3.44), iPhones on iOS 17.4 or later, release and profile builds first, hot reload after shipping.
- **Positioning:** don't sell it as an "Xcode replacement" or use Apple marks in the name or logo. The goal, not yet a claim: "Flutter iOS without a Mac: build, run on your iPhone, ship to TestFlight". Until the gaps above are closed and verified, say only what is verified (README, "Status").

## Spike C: prove App Store acceptance

Pass: the build reaches "Ready to Test" in TestFlight with no ITMS warning, then installs and runs on the iPhone.

Before it starts (decided 2026-10-18: no own account for now, so spike C runs on a test developer team):
- The developer-account holder's written OK: spike C touches their account (an app record, a distribution certificate, uploads) and the licence risk falls on it.
- A separate test app record on that team (e.g. "winCode store test") so the build numbers and TestFlight of the maintainer's real apps stay untouched; the real apps follow once C1 passes.
- Never revoke or replace the team's existing distribution certificate; if a new one is needed, the account holder or an Admin creates it.
- An App Store Connect API key on that team; a final (non-beta) Xcode 26+ .xip (uploads must use Xcode 26 + iOS 26 SDK since 2026-04-28; beta tools are refused).

1. Reference build: same counter app with Xcode on the macOS runner (`flutter build ipa`).
2. Store signing from Windows: CSR, Apple Distribution certificate, App ID, App Store profile via the API; sign with zsign (production entitlements, no get-task-allow).
3. Build metadata: diff Info.plist keys against the reference; fill SDK/platform values from the user's own Xcode files; record any key that can't be filled truthfully.
4. Icon: C1 uses an Assets.car made by actool on the runner (tests the binary alone); C2 repeats with winCode's own Assets.car.
5. Upload: Transporter for Windows (`-assetFile`, API key) first, Build Uploads API second; read Apple's validation details and email.
6. Install from TestFlight (internal testers need no Beta App Review).

| Result | Meaning | Next |
| --- | --- | --- |
| Ready to Test, no warnings | Pure-Windows lane works technically | Build that lane in the Ship phase; run C2 later |
| Fixable error | Packaging gap | Fix, add a doctor check, upload again |
| Toolchain rejection not fixable with honest metadata | Pure-Windows store builds blocked | Cloud Mac lane becomes the store lane for good |

## Spike E: native build hooks

Can winCode run the Dart build hooks of an app's packages for iOS arm64 on Linux, and bundle their output so the app runs on the iPhone?

- **Why:** `path_provider_foundation` 2.6.0 calls Foundation through Dart FFI using `objective_c`, whose build hook compiles Objective-C with clang and runs `xcrun --show-sdk-path`. There is no `xcrun` off macOS, and almost every Flutter app depends on path_provider.
- **How:** run the hooks with Dart's own hook runner and the Swift toolchain's clang for `arm64-apple-ios`, with an `xcrun` shim that points at the Darwin SDK; bundle each dylib as a framework.
- **Plan and pass criteria:** `docs/spikes/spike-e-native-build-hooks.md`. It decides ADR-0010 and runs before the rest of phase 1 (decision 7 below).

## Zero-rejection checks

| Check | Why | When |
| --- | --- | --- |
| Final Xcode 26+ and iOS 26 SDK | Upload requirement since 2026-04-28 | doctor |
| Minimum iOS 13+ | Upload requirement since 2026-09-09 | doctor |
| App icon in Assets.car, CFBundleIconName, 1024 px store icon | Icons come from the asset catalog | build |
| Privacy manifests, required-reason APIs | Required since 2024-05-01 | doctor |
| Purpose string per permission | ITMS-90683 | doctor |
| Device-only arm64, no simulator slices | ITMS-90087 | build |
| Distribution signature on every nested binary; entitlements match profile | signature checks | after signing |
| Launch screen; iPad orientation keys | ITMS-90474 | doctor |
| Build number above last upload | duplicates refused | before upload (API) |
| ITSAppUsesNonExemptEncryption | otherwise each build waits for an export answer | doctor |
| Same structure as Xcode reference IPA | catches the rest | every release (CI) |
| Apple's validation of the upload | final word | after upload (API) |

App Review itself is human; winCode adds a checklist of common guideline rejections and blocking App Store Connect items (age-rating questions since 2026-01-31, EU trader status), but cannot promise approval.

## Two release lanes

Decision record: ADR-0008.

| | Pure Windows | Cloud Mac |
| --- | --- | --- |
| Command | `wincode ship` | `wincode ship --lane mac` |
| iOS SDK runs on | WSL2 on the user's PC | hosted macOS runner in the user's GitHub repo |
| Builder | winCode toolchain | Xcode via `flutter build ipa` |
| Upload | Transporter for Windows / Build Uploads API | same, from the runner |
| Licence | conflicts with the Apple-hardware clause | inside the agreement |
| Toolchain rejection risk | App Store Connect processing: accepted (spike C). App Review: untested | none |
| Cost | free | free on public repos (standard runners); paid minutes on private |
| Default for store builds | after one build has passed App Review + legal review | until then |

**The hybrid lane** is the cloud Mac lane with signing and upload done on Windows, and it is the one real apps use today. A hosted macOS runner in the user's GitHub repo builds the unsigned IPA with Xcode. winCode then signs it with the user's Apple Distribution certificate and App Store profile (ADR-0009), checks it against Apple's requirements, and uploads it through the Build Uploads API. The Apple SDK runs only on the Mac, inside the agreement, and Windows touches no SDK file. It is also the lane for apps whose packages ship compiled asset catalogs, until winCode can produce those (ADR-0012).

## Signing and upload

- **Development signing** stays with xtool (ADR-0006). The App Store Connect API key is the preferred login. A free Apple ID gets short-lived profiles; Apple ID login needs xtool 1.22.2 or later (1.21.0 hit Apple's `-80045`), and accounts with only SMS two-factor authentication still fail (xtool-org/xtool#345).
- **Store signing is winCode's own** (ADR-0009): CSR (OpenSSL), Apple Distribution certificate, App ID and App Store profile through the App Store Connect API; signed with zsign. Store builds never go through xtool provisioning, and winCode never revokes a certificate on its own.
- **Secrets** stay in Windows Credential Manager and are passed per call.
- **Build metadata:** only true values from the user's own Xcode.xip; never fake a Mac build machine (spike C, step 3).
- **Upload:** Transporter for Windows first, the App Store Connect API build uploads (create, reserve, send, commit) second.

## Licence and account risk

The published Xcode and Apple SDKs Agreement (copy dated 2016-08-24) allows installing the software only on Apple-branded computers, forbids running it on other hardware, and forbids reverse engineering. The pure-Windows lane runs the SDK from the user's Xcode.xip on a PC, as xtool does; commentators warned this could risk a developer account. Handling: lawyer review before the pure lane becomes a default; users bring their own Xcode.xip (ADR-0001); spike C on the test developer team only with the account holder's written OK; `wincode setup` and docs state the risk and offer the cloud Mac lane; no reverse engineering of Apple software.

What "legal review" means: a lawyer who knows software licensing reads Apple's two contracts (the Apple Developer Program License Agreement, which governs the account, and the Xcode and Apple SDKs Agreement, which governs Xcode and the SDK) and answers: does building with the SDK on a PC break them, what can Apple do about an upload built that way, and what must winCode tell its users. If paying a lawyer isn't possible yet, the minimum is that the developer-account holder reads those clauses and agrees in writing before spike C, and real releases keep using the cloud Mac lane.

The legal line, unchanged from v1:

- Ship no SDK bits: users download Xcode.xip from Apple and accept its licence themselves, as with xtool. README and `wincode setup` say so.
- Never redistribute SDK headers or libraries, Xcode binaries, Apple fonts, simulator runtimes or developer disk images, including through public CI caches. Never download disk images from third-party mirrors.
- Formats and outputs only (compiled `Assets.car`, Xcode-written Info.plist keys, `.ipa` layout); never decompile Apple tools (`actool`, `ibtool`, CoreUI).
- Clean room for `Assets.car`: A builds samples with real Xcode on Apple hardware (macOS CI) and writes a spec in `docs/formats/`; B implements from the spec only; PRs record provenance.
- No Apple logos; no "Xcode for Windows" tagline.
- Dependency licences: pymobiledevice3 is GPL-3.0 and xcross is AGPL-3.0, so each runs only as a separate process the user installs, never imported into MIT code. zsign and xtool are MIT, the Flutter engine BSD.
- Apple can terminate developer accounts; the README states the risk.
- Not legal advice.

## The emulator question

Chrome DevTools device mode only resizes a web page and changes the user agent; no iOS code runs. winCode's equivalent is `wincode preview`. The Simulator is not an emulator (it runs simulator builds on macOS, on a runtime that needs the macOS kernel), the agreement forbids reverse engineering it, and QEMU iPhone emulators are research-grade with no usable Metal for Flutter.

| Layer | What you see | How | When |
| --- | --- | --- | --- |
| iOS preview on Windows | app with iOS look and behaviour, phone frames, hot reload | Flutter Windows runner with iOS platform behaviour | Preview/Studio phase |
| Mirrored real iPhone | real app on your phone, shown and controlled on the PC | USB screen capture + input via a test agent | spike in that phase |

## Test apps audit and the xcross review

The reference app (a real-world Flutter app with several native plugins, Stripe, and Google and Apple sign-in) uses only SwiftPM plugins, so ADR-0003 holds, yet it cannot build with winCode today: a read-only audit on 2026-10-18 found five gaps. Client details are deliberately left out of this repo.

| Gap | What the audit found | winCode answer |
| --- | --- | --- |
| Native build hook | `path_provider_foundation` 2.6.0 calls Dart FFI through `objective_c` 9.5.0. Its build hook compiles Objective-C with clang and runs `xcrun --show-sdk-path`, which fails off macOS. Most Flutter apps use path_provider. | Spike E: run the hooks ourselves with an `xcrun` shim that points at the Darwin SDK, clang for arm64-apple-ios, then bundle the dylib. |
| Flavors | Several flavors, each with Debug, Release and Profile configurations and an xcconfig that sets bundle ID, name, team, sign-in client IDs and which asset catalogs are included. | winCode reads the Xcode project and xcconfig files itself (phase 1). |
| Engine version | The app builds with Flutter 3.47.5; spike A's `gen_snapshot` is for 3.47.7. | Build `gen_snapshot` per Flutter engine release in CI; `wincode doctor` matches the app's Flutter to a published build. |
| Icon and launch screen | A 1024 px icon and a launch colour in the asset catalog; `Main.storyboard` holds only a FlutterViewController. | The `Assets.car` track already planned; replace the storyboard with code. |
| Unchecked | `stripe_ios` pulls stripe-ios-spm 26.3.0, not cached on the PC; whether it ships prebuilt binary targets is unknown. | Test SwiftPM binary targets in the xtool pipeline. |

Everything else is clean: every native plugin with native code ships a `Package.swift`, and there is no Podfile and no app extension. One finding concerns the app, not winCode: it declares universal-link hosts and a deep-link scheme, but the iOS project has neither the entitlement nor the URL scheme.

**xcross review** (source code read, v2.0.6 released 2026-10-16; not yet run on the iPhone):

- **It breaks the never-revoke rule.** With an API key it revokes every certificate on the team, distribution certificates included, without asking, when creating a certificate hits Apple's limit (HTTP 409) or when its cached certificate has vanished from the team. It also deletes an App ID's development profile when that profile is the only one. xcross never gets a real team's key.
- **It ignores flavors.** It reads only `Debug.xcconfig`, so a flavor build would use the unflavored bundle ID with the name and sign-in settings unresolved.
- **Setup failed three times on this PC, then worked.** It missed the winget alias, Windows PowerShell 5.1 inherited the wrong module path, and the 2.1 GB Swift download dropped after 636 MB and 35 minutes; nothing was installed. On 2026-10-18 a fourth run worked once Swift for Windows was installed first from a resumable, SHA-256-checked download; Swift 6.4.1's own clang 21 and `ld64.lld` meet its LLVM requirement.
- **Windows Defender blocked it.** Right after setup, Defender stopped `xcross.exe` (the official v2.0.6 binary, checksum verified) with a behaviour-based detection, `Behavior:Win32/DefenseEvasion.A!ml`, until the maintainer allowed it. Other Windows users may hit the same.
- **Licence and maturity.** The licence file is AGPL-3.0, so winCode only runs it as a separate tool; one maintainer. CocoaPods-only plugins are skipped with a warning, and the reference app has none.
- **Verdict: unproven.** xcross has what winCode lacks (native Windows, iOS 17+ launch, hot reload, debugging), but it can only be used with a throwaway free Apple ID, or where signing stays out of its hands. The trial continues on the stock counter app.

## Gaps found by real apps

Building a real production app, with a payments SDK built from stock sources as its heaviest dependency, showed where the Linux toolchain is not Xcode. The evidence is in ADR-0012. Each row is a position, not yet a finished piece of work.

| Gap | Position | State |
| --- | --- | --- |
| `Assets.car` | Split it. Catalogs the app owns (icon, PNG image sets, colour sets): the clean-room compiler, PNG only. Catalogs that third-party packages ship (the payments SDK has four, about 1.46 MB, with SVG, PDF and PNG sets): the hybrid lane for now. No SVG or PDF compiler. A catalog cache built in winCode's macOS CI is possible later, after the legal review. "Exact" means equal renditions, checked by a dump from Apple's tools on macOS CI and a device smoke test, not equal bytes | Proposed |
| `#Preview` macros | Previews leave nothing in a release binary, so macro fidelity does not matter. First test a newer OpenAppleMacros; the fallback is to remove `#Preview` blocks from scratch copies of dependency sources, logged | Proposed, untested |
| Cross-import overlays | The SDK declares them, but the `swiftbuild` toolset leaves them off. Pass `-Xfrontend -enable-cross-import-overlays`; a build of the payments SDK without any source change is byte-identical to the one that adds the import by hand | Decided, in a pull request |
| `SwiftUICore` link | The compile step must not autolink it (`-disable-autolink-framework SwiftUICore`), and `buildRunner` fails if the linked runner refers to it. Weak-linking or a higher minimum OS do not fix it | Decided, in a pull request |
| `lld` and `ld` | The linker tag, `LC_SOURCE_VERSION` and the section layout are cosmetic. The behavioural differences (binding, weak links, autolinks) are caught by post-link checks. Gate: one pure-Windows build through App Review before that lane is the default | Proposed |
| `wincode build ipa` | Not ready as a store command. It can start as a thin slice once the points above are settled. It needs the CLI package, a published `gen_snapshot` per Flutter release, the app-owned `Assets.car` compiler and the legal review | Proposed |
| Public release | Source and documentation only (0.1.0), nothing that promises a command that does not exist | Decided |

## Hardening from the xtool teardown

- Secrets: keep the .p8 in Windows Credential Manager, pass it per call, lock ~/.config/xtool to the owner (xtool stores keys in mode-644 files).
- Pin and SHA-256-check the SDK builder's downloads.
- Pass every answer as a flag/stdin line; treat any prompt as an error.
- Warn before touching shared teams (each install re-creates the dev profile with every team device).
- Store builds never go through xtool provisioning (it rewrites bundle IDs to XTL-<prefix>.<id>).
- Extract XcodeSystemResources_Full.pkg (developer disk images) from the user's .xip; xtool's SDK cleanup deletes it.
- Never revoke for the user: winCode lists the certificates and profiles it would change and asks first; it never revokes a distribution certificate on its own. xcross does, which is why it stays away from real teams.
- A lost toolchain must cost an hour: the WSL disk on D: vanished on 2026-10-17 with xtool, the Darwin SDK and the spike files. Setup is one idempotent script (`tools/setup-wsl-toolchain.sh`), and `wsl --export` snapshots the disk once it works.
- Resumable, verified downloads: a 2.1 GB Swift download dropped after 636 MB and 35 minutes. Installers resume interrupted downloads, check SHA-256 and expect flaky networks and little free memory.

## Architecture

winCode is a Dart CLI and a Flutter GUI on Windows that drive a Linux toolchain in WSL2. The iPhone is reached through Apple's device service on Windows (ADR-0005). Development provisioning and signing run in WSL2 through xtool; store signing is winCode's own (ADR-0009).

- **Windows host:**
  - winCode Studio (Flutter GUI) → wincode CLI (Dart, orchestrates everything)
  - Flutter SDK for Windows (frontend_server → app.dill, assets, flutter attach)
  - iOS preview (desktop runner in iOS mode + device frames)
  - Device link: Apple Devices' device service on `127.0.0.1:27015`, used from WSL2 through mirrored networking (ADR-0005); pymobiledevice3 for launch (phase 1) and debugserver (phase 4)
  - App Store client (API key: certs, profiles, build uploads) and Transporter for Windows
- **WSL2 toolchain (Linux):**
  - Darwin Swift SDK (built from the user's Xcode.xip, never shipped)
  - gen_snapshot for iOS (Dart AOT → iOS arm64, built by winCode CI per Flutter engine release, ADR-0004)
  - Swift + LLVM via xtool (compiles runner and plugins, links Mach-O)
  - Dart build hooks for iOS (native assets, ADR-0010)
  - Resources + signing with zsign (Info.plist, Assets.car, provisioning, the .ipa)
- **Outside the PC:**
  - iPhone (USB, iOS 17.4+, Developer Mode)
  - App Store Connect (TestFlight, review)
  - cloud Mac lane: a hosted macOS runner in the user's GitHub repo (ADR-0008)
  - winCode's macOS CI (Xcode oracle tests and reference IPAs)

The two pieces no open-source project provides yet: `gen_snapshot` for iOS on a non-Mac host (done in phase 0, ADR-0004) and an `Assets.car` compiler (phase 2, a parallel track from week 1).

## Build on xtool, don't clone it

xtool already solves half of winCode and is MIT-licensed, so winCode uses it as a tool instead of reverse engineering it. All of winCode's own code, Flutter-specific or not, lives in the winCode repo; winCode does not send changes upstream to xtool (ADR-0006). A copy of xtool's source sits in `third_party/xtool` for reference (ADR-0007).

How xtool works: setup asks you to supply Xcode.xip yourself and builds a Darwin Swift SDK from it on your machine. It then compiles with `swift build --swift-sdk arm64-apple-ios`, signs, installs on a device, and talks to Apple Developer Services through its `XKit` library. It runs on Linux, WSL and macOS.

What xtool does not do, per its author: Interface Builder (storyboards), asset catalogs ("require reverse engineering"), Apple-only macros, LLDB debugging on iOS 17+, and App Store Connect deployment. It builds only SwiftPM packages, not Xcode projects, knows nothing about Dart, `App.framework` or `Flutter.framework`, and makes development certificates and profiles only.

| Need | Reuse | Build new in winCode |
| --- | --- | --- |
| Darwin SDK from Xcode.xip | `xtool sdk` | Windows setup wizard around it |
| Compile runner + plugins | xtool's Swift SDK | Translator: `ios/Runner` + Flutter's SwiftPM plugin package into one SwiftPM package; flavor reader |
| Native build hooks | Dart's hook runner | `xcrun` shim for the Darwin SDK, bundling (ADR-0010) |
| Development account, certificates, App IDs, profiles | XKit | GUI flows |
| Store certificates and profiles | Nothing | App Store Connect API client (ADR-0009) |
| Code signing | zsign (xtool bundles it) | Entitlements merge |
| Install and launch on iPhone | XKit for install (spike B); pymobiledevice3 for launch and debugging | Device link setup through Apple's Windows device service (ADR-0005); developer disk image from the user's Xcode.xip |
| Dart AOT for iOS | Nothing | `gen_snapshot` built on Linux per Flutter engine release (ADR-0004, proven in spike A) |
| App icon in `Assets.car` | Nothing | Clean-room compiler |
| LLDB on iOS 17+ | pymobiledevice3 | Integration |
| App Store upload | Transporter for Windows | Build Uploads API client |

## Build pipeline: Dart source to signed IPA

Store bundle rules (SDK stamp, Info.plist keys, storyboard-free runner, framework signing, shaders): ADR-0011.

1. Read the project: `pubspec.yaml`, `ios/Runner/Info.plist`, entitlements, `AppDelegate.swift`, and flavors, meaning the Xcode project's build configurations and their xcconfig files (bundle ID, display name, team, asset catalogs). Stop with a clear message if a plugin is CocoaPods-only.
2. Native build hooks: run the build hooks of the app's packages for iOS arm64 (for example `objective_c`, which path_provider uses), with an `xcrun` shim that points at the Darwin SDK. Their dylibs are bundled in step 8 (ADR-0010; spike E decides).
3. Dart to kernel: Flutter's `frontend_server` in AOT mode → `app.dill`, with the native-asset mapping from step 2; build `flutter_assets`. Both already run on Windows.
4. Kernel to iOS machine code (ADR-0004):
   - **Tool:** winCode's Linux-built `gen_snapshot` for the user's Flutter version. winCode CI builds and publishes it per Flutter engine release from the `dart_revision` that release pins, and `wincode doctor` matches the app's Flutter version to a published build.
   - **Arguments:** exactly flutter_tools' iOS release arguments, `--snapshot_kind=app-aot-macho-dylib` and the `--macho*` flags.
   - **Output:** gen_snapshot writes the Mach-O `App.framework/App` directly, with the iOS build version, install name, rpaths, compact unwind info and an ad-hoc signature.
   - **Then:** `dsymutil` for the dSYM and `strip -x`. Add `Info.plist` (`io.flutter.flutter.app`, `MinimumOSVersion`) and `flutter_assets` to make `App.framework`.
   - The assembly + `clang` path is not used.
5. Engine: download `Flutter.xcframework` for that engine hash, take the `ios-arm64` slice.
6. Native code: generate one SwiftPM package (Runner + Flutter's generated plugin package + Flutter binary target), `swift build --swift-sdk arm64-apple-ios -c release` in WSL2.
   - Spike B confirmed that `Flutter.xcframework` works as a SwiftPM binary target with xtool.
   - Use the release configuration: debug builds embed build-machine paths in the binary's rpaths.
7. Resources: merge Info.plist; replace storyboards with `UILaunchScreen` + code-created `FlutterViewController` (no `ibtool`); compile the app icon into `Assets.car` + `CFBundleIconName`; copy `PrivacyInfo.xcprivacy` files.
8. Bundle: `Runner.app` with `Frameworks/App.framework`, `Frameworks/Flutter.framework`, plugin frameworks, native-asset frameworks from step 2, `embedded.mobileprovision`.
   - `App.framework` is copied in, not linked. Dart's Mach-O has no exports trie, so the linker refuses it, and the engine loads it at runtime anyway (spike B).
9. Sign inside-out with zsign and merged entitlements: development builds through xtool's provisioning, store builds with winCode's Apple Distribution identity and App Store profile (ADR-0009). Zip `Payload/` → `.ipa`.

Debug builds skip step 4 (kernel blob + engine JIT snapshots) and run only with a debugger attached. Every release is checked by an "oracle" CI job: the same sample built with real Xcode on a macOS runner, bundles diffed. For `gen_snapshot` the oracle already exists: `.github/workflows/spike-a-oracle.yml`.

## Real iPhone: install, launch, logs, hot reload

- Connection (ADR-0005):
  - Apple's device service from the Apple Devices app, reached from WSL2 in mirrored networking mode at `127.0.0.1:27015`.
  - usbipd is not supported: it corrupts large USB transfers.
  - From iOS 17.4 the lockdown tunnel reaches developer services on every platform.
  - Developer Mode must be on. The first launch of a development-signed app needs the developer profile trusted in Settings.
- Release/profile loop (phase 1): build, sign with development profile, install, launch, stream device log. No debugger needed.
  - Spike B proved every step except launch.
  - Launch goes through the user's own Xcode: the personalized developer disk image comes from the user's Xcode.xip (`XcodeSystemResources_Full.pkg`), never from a third-party mirror. pymobiledevice3 on Windows mounts it and launches the app, as a separate process.
- Debug loop with hot reload (phase 4), copying Flutter 3.38+ on Mac:
  1. Build debug (JIT).
  2. Install, launch stopped through `debugserver` over the iOS 17 tunnel.
  3. Attach LLVM `lldb` and load Flutter's LLDB helper (breakpoint on `NOTIFY_DEBUGGER_ABOUT_RX_PAGES`). Since iOS 26 a debug build without a debugger crashes at launch.
  4. Forward the Dart VM service port; `flutter attach --debug-url` from Windows → hot reload, DevTools.
- Support floor v1: Flutter 3.38+, iOS 17.4+, USB first.

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

The first kill switch (`gen_snapshot` on a non-Mac host) was retired on 2026-10-16. The one that remains is Apple accepting a non-Xcode build, which spike C tests.

| Risk | Mitigation | Kill switch / pivot |
| --- | --- | --- |
| `gen_snapshot` for iOS can't be built for Linux/Windows host | Retired 2026-10-16: built on Linux and matched against the Mac output (ADR-0004) | — |
| Dart changes break the Linux `gen_snapshot` build | Anchored GN edits fail loudly; per-release CI with the hash, features and oracle checks (ADR-0004) | Hold that Flutter release until the build is fixed |
| Apple breaks Apple ID login for third-party tools (it did: `-80045`, fixed in xtool 1.22.2 within days) | Track xtool releases; recommend API key login for paid accounts | API key login only |
| The device link breaks (Apple Devices or WSL networking changes) | `wincode setup` checks it (ADR-0005); NAT + port proxy as fallback | Install from Windows with pymobiledevice3 |
| Apple rejects non-Xcode builds | Spike C within three weeks; zero-rejection checks; IPA diff against an Xcode-built copy | The cloud Mac lane becomes the store lane for good (ADR-0008) |
| `Assets.car` too hard | Clean-room spec in `docs/formats/`; PNG sets only (icon, image sets, colour sets); catalogs shipped by packages go through the hybrid lane | Cloud Mac lane for store builds only |
| The Linux toolchain differs from Xcode (macro server, cross-import overlays, linker behaviour) | Compiler options and post-link checks, and a comparison with an Xcode-built copy of the same app (ADR-0012) | The hybrid lane for the affected app |
| App Review rejects a build linked by `lld` | One pure-Windows build through App Review before that lane is the default | The hybrid lane stays the store lane |
| Licence enforcement / bans / takedowns | No SDK redistribution; BYO Xcode.xip; the account holder's written OK for spike C; lawyer review before the pure lane becomes a default | Cloud Mac lane only; drop App Store upload from Windows |
| Native build hooks can't run off macOS | Spike E: run them ourselves with an `xcrun` shim (ADR-0010) | Pin the last plugin-based `path_provider_foundation` (2.5.1); ship such apps through the cloud Mac lane |
| A tool revokes the team's certificates (xcross does) | winCode never revokes on its own (ADR-0009); xcross only with a throwaway free Apple ID | — |
| The toolchain disk is lost (it happened on 2026-10-17) | One idempotent setup script; `wsl --export` snapshot | Rebuild from the script in about an hour |
| Flutter iOS internals change each release | Support latest two stables; CI on stable + beta | — |
| New iOS breaks device protocols | Lean on pymobiledevice3/xtool upstream | — |
| Solo burnout | Narrow v1; two co-maintainers by v0.1; Sponsors | — |

## Next steps

Done since v2:

- [x] Maintainer: merge the xtool teardown and the xtool source copy.
- [x] Maintainer: the developer-account holder's written OK for spike C (`docs/spikes/spike-c-store-acceptance.md`).
- [x] Dev: read-only plugin audit of the reference app (2026-10-18), and the WSL toolchain rebuilt from one script and snapshotted.
- [x] Dev: spike E, native build hooks (2026-10-19): the `xcrun` shim and the hooks on iOS arm64. ADR-0010 stays Proposed.
- [x] Dev: ADR-0008 (two release lanes), ADR-0009 (store signing) and ADR-0010 (native build hooks), all Proposed.
- [x] Dev: cloud Mac lane v0, and spike C1 (uploaded 2026-10-23; Apple processed it as valid).
- [x] Dev: spikes D and F; the core library for flavors, `Info.plist`, `gen_snapshot`, runner and plugin builds, and resource bundles.

Still open from v2, unchanged:

- [ ] Maintainer: a throwaway free Apple ID for the xcross trial, and `xtool auth` with the API key.
- [ ] Dev: the xcross trial on the stock counter app only.
- [ ] Maintainer: before the pure-Windows lane is the default, a legal review, or at least the account holder's informed OK.

New, in order (the maintainer decides what moves):

1. **Now, in pull requests:** the two compiler options (cross-import overlays, no `SwiftUICore` autolink), the README status, ADR-0012, this plan, the CI scan for names, paths and key shapes, the release-please start at 0.1.0, and the macOS-jobs guard.
2. **Done, checked on 2026-11-08:** the repository is public, private vulnerability reporting is on, and the ruleset `main protection` is active. Its history was imported from an earlier private repository (README).
3. **Dev:** a post-link check that no library or binding in the runner is newer than the app's minimum OS, beyond the `SwiftUICore` case.
4. **Dev:** the `wincode_cli` package: `doctor`, `preflight` and `init` are done, and `sign` with an unencrypted key (ADR-0013 phase 3a; encrypted keys are phase 3b). The other hybrid-lane commands are designed in ADR-0013 (Proposed) and come next, ported from the spike scripts in its phase order (`upload`, then `build`), then a pure-Windows build as a thin slice for simple apps. `wincode_asc` for the App Store Connect calls.
5. **CI and Dev:** the macOS oracle for the `Assets.car` image-set and colour-set notes in `docs/formats/` (the A side), then the compiler in a separate session that reads only those notes (the B side).
6. **Maintainer:** one pure-Windows build through Beta App Review or App Review, and the legal review. Only then is the pure lane a candidate for the default.
7. **Dev, with the maintainer's OK to change the SDK setup:** test a newer OpenAppleMacros for the missing `#Preview` macro.
8. Phase 1 continues from issue #7, including per-engine `gen_snapshot` builds.

## Decisions for the maintainer

1. Spike C on a test developer team. Done: the account holder agreed in writing, and C1 was processed as valid.
2. Cloud Mac as the default store lane until one pure-Windows build has passed App Review and the risk is accepted (recommended: yes). In practice the hybrid lane is the store lane today.
3. New phase order, shipping before hot reload (recommended: yes).
4. ADR-0002 (Dart CLI) and ADR-0003 (SwiftPM-only plugins v1): the audit and the real-app builds support accepting ADR-0003, since every native plugin in the reference app is SwiftPM.
5. When the repo goes public, as source and documentation. Done: it is public (checked 2026-11-08); version 0.1.0 is not released yet.
6. Hot-reload phase: build it, or integrate xcross. Undecided: xcross auto-revokes certificates and ignores flavors, so it only runs with a throwaway Apple ID until the trial and a workaround settle it.
7. Spike E (native build hooks) before the rest of phase 1 (recommended: yes, because almost every Flutter app depends on path_provider).

## Sources

- Apple upcoming requirements: https://developer.apple.com/news/upcoming-requirements/
- Transporter user guide: https://help.apple.com/itc/transporteruserguide/en.lproj/static.html
- ASC API build uploads: https://developer.apple.com/documentation/appstoreconnectapi/build-uploads
- Apple developer forums: https://developer.apple.com/forums/thread/14367 · https://developer.apple.com/forums/thread/799875
- Xcode and Apple SDKs Agreement (copy): https://data.gpo.zugaina.org/jm-overlay/licenses/Xcode
- xtool: https://github.com/xtool-org/xtool · announcement: https://forums.swift.org/t/xtool-cross-platform-xcode-replacement-build-ios-apps-on-linux-and-more/79803 · coverage: https://www.osnews.com/story/142331/xtool-cross-platform-xcode-replacement-for-linux-windows-and-macos/
- xtool login fix (`-80045`): https://github.com/xtool-org/xtool/issues/329 · xtool device link on WSL: https://github.com/xtool-org/xtool/issues/19 · usbipd-win: https://github.com/dorssel/usbipd-win/issues/959
- xcross: https://xcross.sh and https://github.com/arxdeus/xcross (LICENSE: AGPL-3.0)
- OpenAppleMacros (the macro server in xtool's Darwin SDK): https://github.com/xtool-org/OpenAppleMacros/releases
- xcbuild: https://github.com/facebook/xcbuild
- Dart build hooks (`hooks`, `hooks_runner`, `code_assets`): https://github.com/dart-lang/native
- Flutter SwiftPM: https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers
- Dart app-aot-macho-dylib commit: https://dart.googlesource.com/sdk/+/38ef28a0589c0ac3009856a636b353e419e25c46%5E%21
- Flutter iOS 26 debug + LLDB: https://startdebugging.net/2026/08/fix-mprotect-failed-permission-denied-in-a-flutter-ios-debug-build/
- pymobiledevice3: https://github.com/doronz88/pymobiledevice3 · zsign: https://github.com/zhlynn/zsign

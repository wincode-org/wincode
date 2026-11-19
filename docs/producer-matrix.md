# Producer matrix: who makes each file of a finished IPA

Status: 2026-11-19. Measured on one real Flutter app with eleven native plugins, built through the hybrid lane (ADR-0008) and compared with an Xcode-built copy of the same app by `tools/ipa-diff`. The app is not named.

A finished IPA is a folder of files. This page puts every file into a group and says who makes that group today when winCode builds the app, and what still needs a tool that runs only on a Mac. It describes the files, not App Review: Apple's processing of these builds and a run on a device are the only acceptance tests so far (PLAN, "Where we stand").

## Words used

| Word | Meaning |
| --- | --- |
| **winCode** | Made on the PC by winCode: its Linux toolchain in WSL2, or Flutter's own tool on Windows. |
| **Copied** | Taken byte for byte from a source that is not the output of an Apple tool: the app's or a package's own files, Google's Flutter engine, or a file Apple's servers issue. |
| **Apple-made** | The output of an Apple tool that runs only on a Mac (`actool`, `ibtool`). winCode has no replacement yet. The builds so far copied these files from an Xcode-built copy of the same app. |
| **Proven** | A build with that file group was processed as valid by App Store Connect and ran on an iPhone. |

## The matrix

The measured IPA has 910 files; the Xcode-built copy has 911. The one file only Xcode's copy has is the ad-hoc signature list of one framework, which signing replaces. Row 7 is part of row 6, so the file counts add up to 910.

| # | File group | Files | Made by | State | How it differs from Xcode's file |
| --- | --- | ---: | --- | --- | --- |
| 1 | Main executable (`Runner`: the app, the plugins and their SwiftPM packages) | 1 | winCode: `swift build` with the Darwin SDK and `lld` in WSL2, driven by `wincode_core` | Proven | Never byte-equal. Linker tag `lld` instead of `ld`; no `LC_SOURCE_VERSION`; `CoreServices` is not linked; `libswiftUniformTypeIdentifiers` is linked strongly where Xcode's link is weak (one weak load command fewer). Every other load command, the rpaths, the platform and the SDK version match. Details: ADR-0012. |
| 2 | `App.framework/App` (the Dart code, ahead of time) | 1 | winCode: `gen_snapshot` built on Linux (ADR-0004) | Proven | Same Flutter, same segment layout, same load commands and build version. The code section is 192 bytes smaller and the constants section 1,456 bytes smaller. The one path-like string that differs is the generated entry file's URI, which carries the build machine's folder (99 characters here, 115 there). That is consistent with the size difference but not shown to be all of it. The ad-hoc signature differs (`gen_snapshot`'s own, not `codesign`'s); signing replaces it. |
| 3 | `App.framework`: `Info.plist`, `flutter_assets` (fonts, images, shaders, manifests) and the framework's ad-hoc `CodeResources` | 425 | winCode: Flutter's tool on Windows, shaders through `impellerc`. `CodeResources` is replaced when signing | Proven | 424 of 425 equal. `NOTICES.Z` has the same text once unpacked; only the gzip header's operating-system byte differs (`0x0a` here, `0x13` there). |
| 4 | `Flutter.framework` (the engine) | 25 | Copied: Google's Flutter engine | Proven | All 25 files equal. The builds so far inherited the folder from the Xcode-built copy; that it equals Google's published artifact for the same engine is not rechecked here. |
| 5 | `objective_c.framework`, from a package's native build hook | 2 | winCode: the hook runs with an `xcrun` shim and clang for iOS in WSL2 (ADR-0010) | Proven | `lld` tag; chained fixups and an exports trie where `ld` writes the older dyld info; no `LC_SOURCE_VERSION`. The framework's `Info.plist` is equal. No signature until signing. |
| 6 | Resource bundles of the SwiftPM packages: 25 bundles | 446 (4 of them are row 7) | winCode: `swift build` copies the files; `wincode_core` writes each bundle's `Info.plist` in Xcode's form | Proven | 417 plain files (strings, PNG, JSON, font, privacy manifests) are byte-equal. Each `Info.plist` equals Xcode's minus four keys (row 14). The other 4 files are the catalogs of row 7. |
| 7 | `Assets.car` inside four third-party bundles (vector and packed images, 1,460,912 bytes) | 4 | **Apple-made** (`actool`), copied | Proven, not produced by winCode | Equal, because they are Xcode's. |
| 8 | `Assets.car` of the app itself (app icon, launch colour; 981,720 bytes) | 1 | **Apple-made** (`actool`), copied | Proven, not produced by winCode | Equal, because it is Xcode's. winCode's own writer is the separate `Assets.car` track. |
| 9 | Loose icon PNGs next to the app's `Assets.car` | 2 | **Apple-made** (`actool` with `--compress-pngs`, which writes Apple's CgBI variant), copied | Proven, not produced by winCode | Equal, because they are Xcode's. |
| 10 | Compiled storyboard (`Main.storyboardc`: two nibs and a plist) | 3 | **Apple-made** (`ibtool`), copied | Proven | Equal, because it is Xcode's. The runner can instead make its window in code and drop the storyboard (ADR-0011 rule 3, spike F). The first grafted builds had none and ran; a later experiment added the Xcode-built storyboard back and the builds after it kept it. |
| 11 | The app's `Info.plist` | 1 | winCode: merges the app's file with the build settings (`wincode_core`) | Proven | Four keys fewer (row 14). The identity keys (bundle ID, name, version, build number) are those of the test app. |
| 12 | `PkgInfo`, the binary `AppFrameworkInfo.plist` and the root `PrivacyInfo.xcprivacy` | 3 | Copied from the Xcode-built copy. Their formats are trivial; winCode has not yet written them itself | Proven | Equal. |
| 13 | Signatures: each Mach-O's code signature, each bundle's `_CodeSignature/CodeResources`, the entitlements | all signed | winCode: zsign in WSL2 or on Linux, with the team's own certificate (ADR-0009, `wincode sign`) | Proven | Not compared with the Xcode copy, which is unsigned at the top level. Checked by `wincode sign` and `wincode preflight` instead. |
| 14 | Four `Info.plist` keys that only Xcode writes: `DTXcode`, `DTXcodeBuild`, `DTCompiler`, `BuildMachineOSBuild` | 4 keys in each of 26 plists | Nobody: winCode never writes them (ADR-0011 rule 2) | Proven: App Store Connect processed builds without them | The only difference left in the 25 bundle plists. |
| 15 | `embedded.mobileprovision` | 1 | Copied: Apple's servers issue it, `wincode` asks for it through the App Store Connect API | Proven | Not in the unsigned Xcode copy. |

## What remains Apple-made

| What | Files | Why winCode cannot make it yet | Path |
| --- | ---: | --- | --- |
| Compiled asset catalogs | 5 in the measured app | `actool` is Apple's, and no open format description covers vector and packed renditions. | The packages' catalogs (4): a cloud job on a macOS runner makes them once, cached by a hash of their inputs (design: a later pull request). The app's own catalog: winCode's clean-room writer, PNG only, a separate track. |
| Loose CgBI icon PNGs | 2 | Same tool, with `--compress-pngs`. | The same cloud job; the flag is part of its recipe. |
| Compiled storyboards and xibs | 3 | `ibtool` is Apple's. | Not needed: put the window in code (ADR-0011 rule 3). None of the app's eleven plugins ships one; the SwiftPM test hosts that do are not linked. |
| Four `Info.plist` keys | 4 per plist | They describe the Xcode that built the app, so any value winCode wrote would be false. | None, by policy. |

Inputs are Apple's too, and stay so: the SDK headers and libraries (the user's own Xcode download, never shipped by winCode), the signing certificate and the provisioning profile, and App Review.

## Patches in what winCode builds

The payments SDK in the measured app builds from source with the four `#Preview` blocks removed (the macro server of the Darwin SDK lacks the preview macros). The patch is recorded in `third_party/README.md`. Nothing else in the dependencies was edited.

## Compiler warnings

The Swift build of the measured app logs 23 distinct warnings. All of them are in the own sources of three plugins (2 in the barcode scanner, 20 in the payments plugin, 1 in the video player). None comes from the runner's sources or from the remote SwiftPM packages. [expected-warnings.tsv](expected-warnings.tsv) lists them by package, file and message, so that a later check can fail on a new warning only.

## Not proven

- Row 1: that URL redirects reach plugins when the runner makes its view controller in code. Google sign-in working in a grafted build does not show it, because every grafted build that ran Google sign-in carried Xcode's storyboard, which makes the view controller the way UIKit does. Only a build with no storyboard and all plugins, run on a device, answers it.
- Row 2: that the build-machine path is the whole of the difference to Xcode's `App`.
- Row 4: that the engine folder equals Google's published artifact; it was inherited.
- Rows 7 to 10 and 12: only copies have been used. Whether an IPA with winCode's own versions passes the same checks is open.
- Every row: App Review has not judged a build made this way.

## How to repeat the check

`tools/ipa-diff <our.ipa> <xcode-built.ipa>` lists Info.plist keys, framework layout, load commands, entitlements and the SHA-256 of every other file. It reads files only and runs no Apple tool. The counts above come from its output and from a file-by-file comparison of the same two IPAs.

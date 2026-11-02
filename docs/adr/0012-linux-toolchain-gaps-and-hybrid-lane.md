# 0012. Linux toolchain gaps, and the hybrid lane for apps that need a Mac build

- Status: Proposed
- Date: 2026-11-02

## Context

The pure-Windows lane (ADR-0008) builds with Swift 6.4.0, the `swiftbuild` build system, xtool 1.22.2's Darwin SDK (iPhoneOS 26.5) and `lld` 21.1.6 inside WSL2. Building a real production app this way, and a payments SDK (stripe-ios-spm 26.3.0, built from stock sources) as its heaviest dependency, showed five places where the Linux toolchain is not Xcode. Details of the app are kept out of this repository, as in `docs/PLAN.md`. Each finding below was reproduced in a small build, and the larger ones were compared with Xcode's output for the same app.

1. **No `actool`.** `swift-build` needs an executable called `actool` to exist even to read its version, for any package that has an asset catalog. The Linux SDK has none, and winCode compiles no catalogs yet (`docs/formats/README.md`). The payments SDK ships four compiled catalogs (about 1.46 MB in total, with SVG, PDF and PNG image sets). A local no-op `actool` got past the check, but it compiles nothing: the four `Assets.car` files had to be copied from an Xcode-built IPA.
2. **`#Preview` macros.** The macro server in the SDK (OpenAppleMacros 1.3.0, pinned by xtool) lacks the UIKit-flavoured preview macro (`KitViewMacro`), so a package that uses `#Preview { SomeUIView() }` does not compile. Previews leave nothing in a release binary: Xcode's release runner of the same app holds no preview registry. OpenAppleMacros has newer releases; whether they cover this is untested.
3. **Cross-import overlays.** The SDK declares them (31 `*.swiftcrossimport` folders, for example `PassKit.framework/Modules/PassKit.swiftcrossimport/SwiftUI.swiftoverlay`), and Xcode loads the overlay when a file imports both modules. The compile command `swift-build` generates carries no option for it, because xtool's `toolset-swb.json` omits `-enable-cross-import-overlays`, which its native `toolset.json` sets. Without it, `PayWithApplePayButton` (after `import SwiftUI` and `import PassKit`) and SwiftUI's `Map` (after `import MapKit`) are not found.
4. **`SwiftUICore` autolink.** SwiftUI's modules ask for `SwiftUICore`, so `lld` links the private framework directly and binds symbols to it. Xcode's linker binds the same symbols to `SwiftUI`, which re-exports it. In the app's runner, Xcode's build binds 254 symbols to `SwiftUI` and none to `SwiftUICore`; the first winCode build bound 252 to `SwiftUI` and 2 to `SwiftUICore` and carried a load command for it. `SwiftUICore` exists only from iOS 18 and the app's minimum is iOS 15, so that runner would very likely not start on iOS 15 to 17 (not run on a device).
5. **`lld` is not `ld`.** The runner's `LC_BUILD_VERSION` names the tool `lld 21.1.6` where Xcode's says `ld 1267.0.0`; `LC_SOURCE_VERSION` is absent; the sections are laid out differently (for example no `__objc_classname`, and a `__literals` section). Apart from item 4, no difference with an effect was found: the builds of the test app that were linked this way were all processed as valid by App Store Connect, and the ones installed on an iPhone ran. None has been through App Review.

## Decision

- **Compile options.** `swiftBuildCommand` passes `-Xfrontend -enable-cross-import-overlays` (item 3) and `-Xfrontend -disable-autolink-framework -Xfrontend SwiftUICore` (item 4). With the first, a build of the payments SDK without any source change is byte-identical to the build that adds `import _PassKit_SwiftUI` by hand. With the second, the runner matches Xcode's in `SwiftUICore` load commands and bindings (0 and 0, with 254 bindings to `SwiftUI`).
- **A post-link check.** `buildRunner` fails if the linked runner has a load command for `SwiftUICore` or a symbol bound to it, with the counts in the message, so item 4 cannot return unnoticed. Other frameworks newer than the app's minimum OS are not checked yet.
- **Hybrid lane for apps with packages that ship compiled catalogs.** Until winCode can produce such catalogs, an app that depends on one is built by Xcode on a hosted macOS runner, which is ADR-0008's cloud Mac lane, and the unsigned IPA is signed and uploaded from Windows with winCode's store signing (ADR-0009). `wincode doctor` is to detect the case by looking for `*.xcassets` in the resolved Swift packages' resources, and to name the lane in its message. Copying `Assets.car` files from a Mac-built IPA into a Windows-built bundle is a diagnostic only. It is never a release route, and a bundle that contains such a file says so in its build notes.
- **No stub catalog compiler is shipped,** and winCode does not fake an `actool` to get past item 1. When winCode has its own catalog compiler, it stands in that place (`docs/PLAN.md`, the `Assets.car` track).
- **`#Preview` (item 2) is not decided.** The first step is to test whether a newer OpenAppleMacros covers the missing macro, as a change to the SDK setup script and its pinned version. The fallback is to remove `#Preview` blocks from scratch copies of dependency sources, logged, never from the user's project and never from a shipped copy.
- **`lld` differences (item 5) are accepted as they are,** with one gate: before the pure-Windows lane becomes the default for any app, a build made that way goes through Beta App Review or App Review once.

## Consequences

- Apps whose packages ship compiled catalogs, a payments SDK among them, cannot use the pure-Windows lane for now. They use the hybrid lane, which needs a GitHub repository and macOS runner minutes (free on public repositories).
- The two compile options apply to every Swift module the command builds. They only change files that import both modules of a declared overlay, and modules that import SwiftUI.
- Some of these findings come from the SDK that xtool builds, not from winCode. ADR-0006 says winCode does not send changes upstream, so they stay recorded here and in the two compile options.
- To revisit: whether a catalog cache or a PNG-only compiler is worth building, whether OpenAppleMacros fixes item 2, and the `lld` differences after the App Review gate.

## Alternatives considered

- **Weak-link `SwiftUICore`.** The two symbols would still be bound to a library that does not exist before iOS 18.
- **Raise the app's minimum OS to 18.** It changes the product, and Xcode's build of the same app supports iOS 15.
- **`-Xlinker -no_implicit_dylibs`.** `SwiftUICore` stayed, and two libraries that Xcode's runner links (`AVFAudio`, `CoreFoundation`) disappeared.
- **Add `import _PassKit_SwiftUI` to the dependency.** It works, but it edits third-party source, and the compile option makes the same build without any edit.
- **A script that adds missing overlay imports to every file.** The compiler option does the same thing without touching sources.
- **A no-op `actool` shipped with winCode.** It would hide the missing catalogs behind a silent success.
- **A catalog compiler for SVG and PDF image sets.** A large, hard-to-check format, for a need that only third-party packages have. Not before the PNG case (app icon, image sets and colour sets) works.
- **Per-package-version catalogs built once in winCode's macOS CI and cached.** Possible later. Redistributing the output of Apple's tool needs the legal review first (`docs/PLAN.md`, "Licence and account risk").

# 0010. Run Dart build hooks ourselves, with an xcrun shim for the Darwin SDK

- Status: Proposed
- Date: 2026-10-18

## Context

- Dart packages can ship build hooks (`hook/build.dart`) that compile native code for the target platform. On macOS, `flutter build ios` runs them and embeds their output as frameworks. winCode doesn't run `flutter build ios`, so nothing runs the hooks.
- `path_provider_foundation` 2.6.0 replaced its Flutter-plugin implementation with direct FFI calls to Foundation, through `objective_c` 9.5.0. That package's hook compiles Objective-C with clang into a dynamic library and runs `xcrun --show-sdk-path --sdk iphoneos`, which fails off macOS.
- Almost every Flutter app depends on path_provider. The reference-app audit hit this (`docs/PLAN.md`, "Test apps audit and the xcross review").

## Decision

To be confirmed or rejected by spike E (`docs/spikes/spike-e-native-build-hooks.md`):

- **winCode runs the hooks itself,** in WSL2, with Dart's own hook runner (`package:hooks_runner`, the backend flutter_tools uses), for target OS iOS, SDK `iphoneos`, arm64 and the app's minimum iOS version.
- **The C compiler is the Swift toolchain's clang** for `arm64-apple-ios`, passed in the build input.
- **An `xcrun` shim** on the hooks' `PATH` answers SDK-path queries with the Darwin SDK built from the user's Xcode.xip, and fails loudly on anything else, so every new kind of call shows up.
- **Hook output is bundled as Flutter bundles it:** each dylib becomes a framework in `Frameworks/`, signed with the app, and the Dart compile step gets the native-asset mapping.

## Consequences

- Apps that use path_provider, or any other package with hooks, build without a Mac.
- winCode follows the hooks protocol (`package:hooks`, `package:code_assets`) as it changes, and tests it per Flutter release.
- The shim stays small and honest: it reports paths into the user's own SDK; it does not imitate Xcode's tools.
- A hook that needs another macOS-only tool fails with a clear message that names the package.

Spike E results (2026-10-19, `docs/spikes/spike-e-native-build-hooks.md`):

- **The approach works.** `objective_c` 9.5.0's hook ran on Linux through `hooks_runner` 1.5.0 with one shim answer, the SDK path. On an iPhone 15 with iOS 27.0.1, `path_provider` 2.6.0 returned the app's documents directory. The comparison with an Xcode-built reference IPA is still open.
- **The C compiler must link with an iOS-capable `ld64.lld`.** That means `clang -B <Darwin SDK toolset> -fuse-ld=lld`:
  - The Swift toolchain's own lld refuses iOS.
  - A bare `--ld-path` makes clang pass ld64 flags that lld rejects.
  - LLD warns that iOS is unsupported. It is the same linker xtool uses for every iOS app.
- **winCode must build `flutter_assets` itself for apps with hooks.** `flutter build bundle --target-platform ios` runs the hooks too and stops off macOS ("Failed to find xcrun"). The spike's stopgap, a copy of the app without the hook packages, loses those packages' licences from `NOTICES`.
- **The Dart compile needs Flutter's plugin registrant,** or Dart-only plugin implementations such as `path_provider_foundation` are never registered. Flutter 3.47 ships the native-asset mapping as `flutter_assets/NativeAssetsManifest.json`, not in the kernel.
- **winCode needs its own install-name edit.** Linux has no `install_name_tool` or `lipo`, so winCode needs a Mach-O edit of its own, or `llvm-install-name-tool`, to set each framework's `@rpath` install name.
- **Store signing must leave entitlements off embedded frameworks (ADR-0009).** xtool's signer gives every embedded framework the app's entitlements, and iOS logs an AMFI notice. Development builds still run.
- **The 2.5.1 fallback** resolves on Flutter 3.47.7 and runs no hooks. It needs the SwiftPM plugin path of phase 1 instead, and it was not run on the device.

## Alternatives considered

- **Pin the last plugin-based `path_provider_foundation` (2.5.1)** with a dependency override: quick, but it fights version constraints and doesn't help other packages with hooks.
- **Prebuilt dylibs from macOS CI for each package version:** no hooks run on the user's PC, but winCode would have to build and host binaries for every version of every such package.
- **Build such apps only in the cloud Mac lane** (ADR-0008): works for store builds, not for `wincode run` on the PC.

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

## Alternatives considered

- **Pin the last plugin-based `path_provider_foundation` (2.5.1)** with a dependency override: quick, but it fights version constraints and doesn't help other packages with hooks.
- **Prebuilt dylibs from macOS CI for each package version:** no hooks run on the user's PC, but winCode would have to build and host binaries for every version of every such package.
- **Build such apps only in the cloud Mac lane** (ADR-0008): works for store builds, not for `wincode run` on the PC.

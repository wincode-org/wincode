# Spike E: Dart build hooks for iOS without macOS

Status: planned, 2026-10-18. No results yet. It decides ADR-0010 and runs before the rest of phase 1.

## Question

Can winCode run the build hooks of an app's Dart packages for iOS arm64 on Linux (WSL2), and bundle their output so the app works on an iPhone?

## Why

- `path_provider_foundation` 2.6.0 calls Foundation through Dart FFI using `objective_c` 9.5.0.
- `objective_c`'s hook (`hook/build.dart`) compiles its Objective-C sources with clang into a dynamic library. For the SDK it runs `xcrun --show-sdk-path --sdk iphoneos`, and when the build input names no C compiler it falls back to `clang` on `PATH`.
- There is no `xcrun` off macOS, so the hook fails. On macOS `flutter build ios` runs the hooks; winCode doesn't use it.
- Almost every Flutter app depends on path_provider, so this blocks gate G1.

## Inputs

| Item | Value |
| --- | --- |
| Test app | Stock `flutter create` counter plus `path_provider`, showing `getApplicationDocumentsDirectory()` on screen |
| Packages | Whatever pub resolves; record every package that has a `hook/build.dart` and its version (expected: `objective_c` only) |
| Toolchain | WSL2 from `tools/setup-wsl-toolchain.sh`: Swift 6.4, xtool 1.22.2, Darwin SDK from Xcode 26.6 |
| Device | iPhone on iOS 17.4 or later, through Apple's device service (ADR-0005) |
| Reference | The same app built with `flutter build ipa` on the macOS runner |

## Method

1. **Find the hooks.** List the packages in the resolved graph that have `hook/build.dart`.
2. **`xcrun` shim.** A small script, first on the hooks' `PATH`, that answers `xcrun --show-sdk-path --sdk iphoneos` with the `iPhoneOS.sdk` path inside the Darwin SDK, logs every call, and exits non-zero on any other request.
3. **Run the hooks** with `package:hooks_runner` from a small Dart program in WSL2: target OS iOS, SDK `iphoneos`, arm64, the app's minimum iOS version, dynamic linking, and the Swift toolchain's clang as the C compiler. Fallback: write the build input by hand and run `dart run hook/build.dart --config input.json`.
4. **Check the dylib** with `file` and `llvm-objdump --macho --private-headers`: arm64 Mach-O, `LC_BUILD_VERSION` for iOS with the right minimum, an `@rpath` install name. Compare it with the one in the reference IPA.
5. **Bundle** as flutter_tools does: wrap the dylib as a framework in `Frameworks/`, give the Dart compile step the native-asset mapping, then sign and install with xtool. `App.framework` comes from the Linux `gen_snapshot` (spike A scripts), or from the macOS runner if that isn't rebuilt yet: the subject here is the hook output, not `gen_snapshot`.
6. **Run on the iPhone:** the screen shows a real documents path, and the device log has no `dlopen` or missing-symbol errors.
7. **Compare with the reference IPA:** the framework's layout, `Info.plist` and load commands.

## Pass criteria

- **GREEN:** the hook runs on Linux with only the shim's SDK path; the dylib is a valid iOS arm64 Mach-O; the app on the iPhone shows the documents path; the framework matches the reference except for signatures and UUIDs. ADR-0010 is accepted as written.
- **AMBER:** it works, but only with hook-specific workarounds (more shim answers, edited build inputs, a patched hook). ADR-0010 is accepted with each workaround listed, and each becomes a `wincode doctor` check.
- **RED:** the hook needs macOS-only tools that cannot be replaced honestly. ADR-0010 is rejected and its alternatives apply: pin the last plugin-based `path_provider_foundation` (2.5.1), or ship such apps through the cloud Mac lane (ADR-0008).

## Out of scope

- Other targets (simulator, macOS).
- Link hooks (`hook/link.dart`) and tree-shaking of native assets.
- Changes to the packages themselves.

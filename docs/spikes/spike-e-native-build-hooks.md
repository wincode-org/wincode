# Spike E: Dart build hooks for iOS without macOS

Status: run 2026-10-19 (parts 1 and 2). **Result: the hook question is answered yes.** All GREEN criteria are met except one not yet tested: step 7, the comparison with an Xcode-built reference IPA, was not run. ADR-0010 stays Proposed.

## Question

Can winCode run the build hooks of an app's Dart packages for iOS arm64 on Linux (WSL2), and bundle their output so the app works on an iPhone?

## Result

- **The hook ran on Linux.** `objective_c` 9.5.0's `hook/build.dart` ran through `package:hooks_runner` 1.5.0 with the same build input flutter_tools uses on macOS. It compiled its 8 C and Objective-C sources against the Darwin SDK and linked `objective_c.dylib`. The `xcrun` shim saw exactly one call: `xcrun --show-sdk-path --sdk iphoneos`.
- **The dylib is a valid iOS arm64 Mach-O:** `Mach-O 64-bit arm64 dynamically linked shared library`, `LC_BUILD_VERSION` platform ios, minos 15.0, sdk 26.5. Its only load command for a library is `/usr/lib/libSystem.B.dylib`, because the hook links with `-undefined dynamic_lookup`.
- **It runs on the iPhone.** The app showed `documents: /var/mobile/Containers/Data/Application/<uuid>/Documents`, and the device log has the same line from Dart (`flutter: spike-e documents: …`). No `dlopen` or missing-symbol errors.
- **Not done:** step 7, the comparison with the same app built by Xcode on the macOS runner.

The C compiler handed to the hooks is a wrapper (`spikes/e-native-build-hooks/clang-ios`): the Swift toolchain's clang with `-B <Darwin SDK toolset> -fuse-ld=lld`. It configures the toolchain for every hook rather than working around this one, so it is not an AMBER workaround. Finding 1 explains why it is needed.

## Findings

1. **Linker.** The hook links by calling clang directly, so clang has to find a linker that can link for iOS.
   - The Swift 6.4 toolchain's own `ld64.lld` refuses iOS ("This version of lld does not support linking for platform iOS").
   - Pointing clang at the Darwin SDK's `ld64.lld` with `--ld-path` makes clang pass old ld64 flags that lld rejects ("must specify -platform_version", "missing or unsupported -arch arm64").
   - What works is `-B <toolset> -fuse-ld=lld`. LLD 21.1.6 from xtool's toolset then links, with a warning: "This version of lld does not support linking for platform iOS. Proceed at your own risk." This is the same linker xtool uses for every iOS app, spike B's included.
2. **`flutter build bundle` can't make the asset bundle for an app with hooks on Linux.**
   - With `--target-platform ios`, Flutter runs the hooks itself and stops: `Target build_hooks failed: ProcessException: Failed to find "xcrun" in the search path.`
   - Turning native assets off (`FLUTTER_NATIVE_ASSETS=false`) makes Flutter refuse the package instead.
   - Making Flutter's own path work would need `xcrun --find clang/ar/ld`, an `SdkRoot` define, `lipo`, `strip`, `install_name_tool` and `codesign`, which ADR-0010 rules out.
   - In this spike, `flutter_assets` comes from a copy of the app without the hook packages (`hooks_app_bundle`). Its `NOTICES` lack those packages' licences, which is acceptable for a spike but not for shipping.
3. **The kernel needs Flutter's Dart plugin registrant.** Spike A's kernel step didn't include it. Without it, `path_provider_foundation` (a `dartPluginClass`) never registers, and tree shaking removes its FFI code. `make_app.sh` now generates `.dart_tool/flutter_build/dart_plugin_registrant.dart` from Flutter's template and passes it as flutter_tools does (`--source …`, `-Dflutter.dart_plugin_registrant=…`). Afterwards the kernel contains `objective_c`'s bindings.
4. **The native-asset mapping is a runtime manifest.** Flutter 3.47 doesn't compile it into the kernel. It ships it as `flutter_assets/NativeAssetsManifest.json` (flutter_tools `build_system/targets/ios.dart`), so this spike does the same:
   `{"format-version":[1,0,0],"native-assets":{"ios_arm64":{"package:objective_c/objective_c.dylib":["absolute","objective_c.framework/objective_c"]}}}`
5. **The framework follows flutter_tools' layout** (`isolated/native_assets/ios/native_assets.dart`):
   - `objective_c.framework/objective_c`
   - install name `@rpath/objective_c.framework/objective_c`
   - Flutter's `Info.plist` (`io.flutter.flutter.native-assets.objective-c`, `FMWK`, `MinimumOSVersion` 15.0)
   - a dSYM, and the binary stripped with `strip -x`
   - The Linux toolchain has no `install_name_tool` or `lipo`. The spike rewrites `LC_ID_DYLIB` in place, which works when the new name fits; winCode needs its own Mach-O edit or `llvm-install-name-tool`.
6. **xtool gives every embedded framework the app's entitlements.** On launch, iOS logs `AMFI: constraint violation … has entitlements but is not a main binary` for `App.framework`, `Flutter.framework` and `objective_c.framework`. This doesn't stop development builds. Store signing must sign frameworks without entitlements (ADR-0009).
7. **xtool exits 0 when it cancels.** Without a terminal, its revocation prompt reads as "no": it prints `Cancelled.` and exits 0. The wrapper has to look for that line instead of trusting the exit code.
8. **A lost disk forces a certificate revocation.** The WSL disk took xtool's signing private key with it, so the first install afterwards had to revoke the old development certificate on the personal team (see Team safety). winCode should back up that identity, or say in advance that this will happen.

## Fallback: `path_provider_foundation` 2.5.1

- It resolves on Flutter 3.47.7 (`sdk: ^3.9.0`, `flutter: ">=3.35.0"`) and pulls in neither `objective_c` nor `ffi`, so no hooks run.
- It is the Swift plugin: `darwin/path_provider_foundation/Package.swift`, `pluginClass: PathProviderPlugin`, with Pigeon. It needs phase 1's SwiftPM plugin build and native registration in the runner.
- It wasn't built or run here. It stays a fallback for one package; it is not a general answer for packages with hooks.

## Versions and numbers

| Item | Value |
| --- | --- |
| Flutter | 3.47.7: engine `deb287481e`, Dart 3.13.5 |
| Packages | `path_provider` 2.1.6, `path_provider_foundation` 2.6.0, `objective_c` 9.5.0 (the only package with a hook), `ffi` 2.2.0 |
| Hooks protocol | `hooks_runner` 1.5.0, `hooks` 2.0.2, `code_assets` 1.2.1, as flutter_tools 3.47.7 pins them |
| Build input | `target_os` ios, `target_architecture` arm64, `link_mode_preference` dynamic, `ios` `{target_sdk: iphoneos, target_version: 15}`, `c_compiler` `{cc: clang-ios, ld: <toolset>/ld64.lld, ar: llvm-ar}` |
| Hook link step | `clang -shared -Wl,-encryptable -undefined dynamic_lookup -isysroot <iPhoneOS.sdk> -target arm64-apple-ios -mios-version-min=15 <objects> -o objective_c.dylib` |
| Toolchain | Swift 6.4.0 (clang 21), Darwin SDK from Xcode 26.6 (iPhoneOS 26.5 SDK), xtool 1.22.2 |
| Device | iPhone 15 (`iPhone15,4`), iOS 27.0.1 (24A446), through Apple's device service (ADR-0005) |
| `setup.sh` | 511 s in all, including 134 s for the `gen_snapshot` build |
| Cold hook run | 13 s (compiles the hook, then its sources, then links) |
| `assemble.sh` | about 90 s per app |
| xtool sign and install | 12 s |
| Unsigned IPA | 6.6 MB (hooks app), 6.7 MB (counter control) |

Both `App.framework`s carry Flutter 3.47.7's snapshot hash. The counter app is the control: no hooks, and the same runner and steps.

## Team safety

- xtool was logged in with an Apple ID (personal team), which the maintainer did.
- One certificate was revoked, with the maintainer's explicit approval: the Apple Development certificate xtool had made for spike B on 2026-10-16, whose private key was lost with the WSL disk.
  - xtool asked once.
  - The answer was given only after checking that the prompt listed exactly that one certificate.
  - xtool then made a new development certificate.
- xtool re-creates its App ID's development profile on each install. The bundle ID is spike B's, so no new App ID was expected. Only this iPhone was involved.

## Reproduce

In WSL2, after the toolchain script, with `xtool auth login` done for part 2:

```bash
bash spikes/e-native-build-hooks/setup.sh       # Flutter 3.47.7, iOS artifacts, Linux gen_snapshot
bash spikes/e-native-build-hooks/make_apps.sh   # test apps in ~/spikes/spike-e
BUNDLE_APP=~/spikes/spike-e/hooks_app_bundle \
  bash spikes/e-native-build-hooks/assemble.sh ~/spikes/spike-e/hooks_app ~/spikes/spike-e/out/hooks_app
bash spikes/e-native-build-hooks/assemble.sh ~/spikes/spike-e/counter ~/spikes/spike-e/out/counter
bash spikes/b-device/install.sh ~/spikes/spike-e/out/hooks_app/runner   # stops at any xtool prompt
bash spikes/b-device/logs.sh 600 ~/spikes/spike-e/out/hooks_app/device.log
```

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

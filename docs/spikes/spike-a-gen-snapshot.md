# Spike A: gen_snapshot for iOS arm64 on a Linux host (phase A0 recon)

Status: phase A0 (recon) done, 2026-10-12. Nothing has been built from source yet. Phase A1 needs approval.

## Question

Can a non-Mac host produce the iOS release AOT output (`App.framework/App`) that the matching prebuilt `Flutter.framework` will load? If not, winCode needs a Mac somewhere in the release pipeline (see the kill switch in `docs/PLAN.md`).

## Verdict criteria

- **GREEN:** a gen_snapshot running natively on Linux x64 produces the iOS arm64 AOT output, with a hash and features string matching the pinned Flutter.framework, and we can turn it into an arm64 Mach-O App.framework/App on Linux. Proof on the device comes in spike B.
- **AMBER:** it only works through emulation, or needs heavy patching on every Flutter release.
- **RED:** it is impossible without macOS. The project would then need a remote Mac or CI fallback.

**A0 assessment: GREEN is likely, not yet proven.** Nothing found in the source requires macOS to *produce* the output. The remaining blocker is build plumbing (GN/toolchain checks that assume a Mac host), not code generation.

## Pinned versions

| Item | Value |
| --- | --- |
| Flutter | 3.47.7 stable, released 2026-10-08 |
| Framework revision | `abaf9c523780a608bd46686fd5e53740a07077f8` |
| Engine revision (`bin/internal/engine.version`) | `deb287481e3ce9468f3434937ced4240a70539ca` |
| Engine content hash | `d8a2d6c768c334d53e16277f837970ffa1e2de81` |
| Dart SDK | 3.13.5 |
| `dart_revision` (root `DEPS`) | `04bcd1036cdc799ac6564988f159ee454d42c822` |
| Snapshot hash | `0451907c2eaa8467e848c0067bfe8ed4` |
| iOS deployment target used by flutter_tools | 15.0 |

Since the monorepo merge, `engine/src/flutter` and the engine `build/` directory are part of the flutter/flutter checkout, and `DEPS` lives at the repo root.

## Environment

- WSL2 Ubuntu 24.04, 12 vCPU, 10 GiB RAM visible, about 938 GB free in the distro's virtual disk and 83.8 GB free on the D: drive that holds it.
- Swift 6.4 via swiftly. Its LLVM is `clang version 21.0.0` (swiftlang fork), and it ships `ld64.lld`, `ld.lld`, `llvm-objdump`, `llvm-nm`. No `lipo`/`llvm-lipo`, `otool` or `ld64`.
- xtool 1.21.0 Darwin SDK at `~/.swiftpm/swift-sdks/darwin.artifactbundle` (`iPhoneOS26.5.sdk`), with its own `toolset/bin/ld64.lld` and `dsymutil`.
- WSL has no Flutter of its own. `flutter` on PATH resolves to the Windows install through `/mnt/c`, so the spike puts its pinned clone first on PATH.
- Scratch space: `~/spikes/spike-a/` inside WSL, about 3.7 GB after A0 (Flutter clone + cache 3.0 GB, iOS artifacts 0.6 GB, Dart sparse checkout 73 MB).

## iOS release pipeline (flutter_tools at 3.47.7)

Sources: `packages/flutter_tools/lib/src/base/build.dart` (`AOTSnapshotter`), `lib/src/build_system/targets/ios.dart` (`AotAssemblyRelease`, `ReleaseIosApplicationBundle`), `lib/src/build_system/targets/common.dart` (`KernelSnapshot`, `Lipo`).

1. **Kernel (target `kernel_snapshot_program`).** Exact command, captured from `flutter assemble -v` on Linux:
   ```
   bin/cache/dart-sdk/bin/dartaotruntime \
     bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot \
     --sdk-root bin/cache/artifacts/engine/common/flutter_patched_sdk_product/ \
     --target=flutter --no-print-incremental-dependencies \
     -Ddart.vm.profile=false -Ddart.vm.product=true \
     --delete-tostring-package-uri=dart:ui --delete-tostring-package-uri=package:flutter \
     --aot --tfa --target-os ios \
     --packages <app>/.dart_tool/package_config.json \
     --output-dill <build>/app.dill --depfile <build>/kernel_snapshot_program.d \
     --verbosity=error [--recorded-uses=<build>/recorded_uses.json] \
     package:<app>/main.dart
   ```
   User `--dart-define`s are appended as `-D` flags, plus `FLUTTER_APP_FLAVOR` when a flavor is set. `--target-os ios` comes from the `TargetPlatform.ios => 'ios'` switch in `KernelSnapshot`.
2. **AOT (target `aot_assembly_release`).** One `gen_snapshot` per arch; iOS release is arm64 only:
   ```
   gen_snapshot_arm64 --deterministic \
     --snapshot_kind=app-aot-macho-dylib \
     --macho=<build>/arm64/App.framework/App \
     --macho-object=<build>/arm64/app.o \
     --macho-min-os-version=15.0 \
     --macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks \
     --macho-install-name=@rpath/App.framework/App \
     [--dwarf-stack-traces --resolve-dwarf-paths --save-debugging-info=<dir>/app.ios-arm64.symbols] \
     [--obfuscate] \
     <build>/app.dill
   ```
   **gen_snapshot writes the Mach-O dylib itself. There is no assembly + `clang` step at this tag.** Path A of the plan (assembly to clang) is obsolete; `app-aot-macho-dylib` is the production path.
3. **Lipo.** `lipo <arch outputs> -create -output <build>/App.framework/App`, run even for one arch. On Linux, a copy (or `llvm-lipo`) is enough.
4. **Debug symbols (release/profile).** `xcrun dsymutil -o App.framework.dSYM App.framework/App`, then `xcrun strip -x App -o App`. These are optional for a working app; `dsymutil` exists in the xtool toolset, and LLVM has `llvm-strip`.
5. **Bundle (target `release_ios_bundle_flutter_assets`).** `App.framework/` contains `App`, `flutter_assets/` (assets, fonts, shaders, `NativeAssetsManifest.json`) and `Info.plist`. `Info.plist` is a copy of `ios/Flutter/AppFrameworkInfo.plist` (`CFBundleExecutable=App`, `CFBundlePackageType=FMWK`, ...), with `MinimumOSVersion` set to 15.0 by `plutil -replace`.
6. **Framework signing.** `codesign --force --sign <identity or '-'>`, plus `--timestamp=none` for non-release. In winCode, zsign does this.
7. **Engine.** `Flutter.framework` comes prebuilt from `ios-release/artifacts.zip`, slice `Flutter.xcframework/ios-arm64`.

## What already works on Linux

- `flutter precache` (2.7 GB cache in total) and **`flutter precache --ios` both work on Linux.** The latter downloads `ios`, `ios-profile` and `ios-release` into `bin/cache/artifacts/engine/` in 22 s.
- `ios-release/artifacts.zip` (140,754,542 bytes; MD5 matches the GCS `x-goog-hash`) is identical to what precache unpacks, apart from a `LICENSE` file.
- **The iOS release kernel compile is host-independent.** In `counter/` (a default `flutter create` app), `flutter assemble -dTargetPlatform=ios -dBuildMode=release kernel_snapshot_program` finished in 7 s. Re-running the exact command above directly, outside flutter_tools, gave a byte-identical file:
  - `app.dill`: 23,202,336 bytes
  - sha256 `69ed0535ad882e972a2289fda7751748f0f12fb74aab7bfbb2a97b41f11d8bcb`

## Snapshot compatibility (hash and features)

| Binary | `file` | 32-hex snapshot hash |
| --- | --- | --- |
| `Flutter.xcframework/ios-arm64/Flutter.framework/Flutter` | Mach-O 64-bit arm64 dylib | `0451907c2eaa8467e848c0067bfe8ed4` |
| `gen_snapshot_arm64` (iOS release) | Mach-O universal: x86_64 + arm64 macOS executables | `0451907c2eaa8467e848c0067bfe8ed4` (both slices) |
| `android-arm64-release/linux-x64/gen_snapshot` | ELF x86-64 | `0451907c2eaa8467e848c0067bfe8ed4` |

Each binary contains exactly one 32-hex string, and it is the same in all three. **The snapshot hash depends on the Dart revision, not on the target OS.** A gen_snapshot built from `dart_revision` on Linux will carry the same hash.

The features string is assembled at runtime (`Dart::FeaturesString` in `runtime/vm/dart.cc`). For code snapshots it ends with the arch, then the OS, then the pointer mode:
- `arm64`
- the OS: `ios` when `DART_TARGET_OS_MACOS_IOS` is defined, `macos` for plain `DART_TARGET_OS_MACOS`
- `compressed-pointers` or `no-compressed-pointers`

Observed fragments:
- The iOS `Flutter` binary and `gen_snapshot_arm64` both contain ` arm64`, ` ios` and ` no-compressed-pointers`.
- The Linux-host Android gen_snapshot contains ` android` and ` compressed-pointers` instead.

As a format check, the Android gen_snapshot compiled the counter `app.dill` into an ELF whose header reads:

```
0451907c2eaa8467e848c0067bfe8ed4product no-asan no-msan no-tsan no-shared_data no-code_comments no-dwarf_stack_traces arm64 android compressed-pointers
```

So the expected iOS release header is the same prefix ending in `arm64 ios no-compressed-pointers`. This is inferred from source and fragments; the full string has not been observed yet. A Linux build of gen_snapshot must therefore define the iOS target OS, use `dart_use_compressed_pointers=false` (the Dart default), and be a product build.

## gen_snapshot target-OS findings

### 6b. The target OS is chosen at compile time, with no runtime flag

- `runtime/BUILD.gn`, `config("dart_os_config")`: GN `target_os == "ios"` adds `DART_TARGET_OS_MACOS` and `DART_TARGET_OS_MACOS_IOS`. `"linux"` adds `DART_TARGET_OS_LINUX`, `"android"` adds `DART_TARGET_OS_ANDROID`, and so on.
- `runtime/platform/globals.h`: if no target OS is defined, it falls back to the host OS.
- `runtime/bin/gen_snapshot.cc` has no target-OS option, only `--snapshot_kind` (`app-aot-assembly`, `app-aot-elf`, `app-aot-macho-dylib`, `app-aot-pecoff-obj`, ...) and output paths.
- In GN, `target_os` is global. A gen_snapshot built in the host toolchain (`current_os = linux`) still sees `target_os = "ios"`. That is exactly how the Mac host builds the iOS gen_snapshot today.
- Host-specific system headers are guarded by `DART_HOST_OS_*`, not `DART_TARGET_OS_*`. Examples: `<mach/...>` in `vm/virtual_memory_posix.cc`, `<libkern/OSCacheControl.h>` in `vm/cpu_arm64.cc`, `<os/signpost.h>` in `vm/timeline.cc`. So a Linux host compiling with iOS target defines is expected to work, the same way the Linux-host Android gen_snapshot already does.

### 6c. What differs when the target is iOS

| Area | File | iOS behaviour |
| --- | --- | --- |
| Platform register | `vm/constants_arm64.h` (`R18 ... reserved on iOS`), `vm/compiler/backend/locations.h` | R18 is excluded from allocation under `DART_TARGET_OS_MACOS` |
| Stack arguments | `vm/constants_arm64.h` | Apple rule: arguments may use stack slots that are not multiples of 8 bytes (`kArgumentStackAlignment`) |
| Argument/return extension | `vm/constants_arm64.h` | `kExtendedTo4` on Apple targets |
| Loop alignment | `vm/constants_arm64.h` | `kPreferredLoopAlignment = 1` on Apple targets, 32 elsewhere |
| Atomics | `vm/cpu_arm64.h` | LSE atomics assumed only for macOS (ARMv8.5), not iOS |
| FFI ABI | `vm/compiler/ffi/abi.cc`, `native_calling_convention.cc`, `marshaller.cc`, `native_type.cc` | ABI name `IOS`, Apple calling convention |
| Assembly output | `vm/image_snapshot.cc` | Mach-O sections (`__DWARF,...`, `.const`), no `.type`/`.size`; CFI emitted per function on arm64 Apple (`EMIT_UNWIND_DIRECTIVES_PER_FUNCTION`) |
| Mach-O writer | `vm/mach_o.cc`, `vm/mach_o.h`, `vm/so_writer.h`, `platform/mach_o.h` | `LC_BUILD_VERSION` with `PLATFORM_IOS`, `LC_ENCRYPTION_INFO` on by default for iOS |
| Features string | `vm/dart.cc` | ` ios` |

`platform/mach_o.h` includes only `platform/globals.h`. It is Dart's own definition of the format, not Apple's `<mach-o/loader.h>`.

### 6d. `--snapshot_kind=app-aot-macho-dylib` at this Dart revision

- It is the kind flutter_tools uses for iOS and macOS at 3.47.7 (`build.dart`, `AOTSnapshotter.build`).
- Flags:
  - `--macho`, `--macho-object` (an `app.o` written at the same time)
  - `--macho-min-os-version`, `--macho-rpath`, `--macho-install-name`
  - `--macho_linker_signature` (default true: an ad-hoc, linker-style `LC_CODE_SIGNATURE`)
  - `--macho_encryptable` (default true on iOS)
  - `--macho_reduce_padding`
- **The output targets iOS.** `MachOBuildVersion` returns `PLATFORM_IOS` under `DART_TARGET_OS_MACOS_IOS`.
- **Compact unwind info is no longer missing.** `vm/mach_o.cc` now generates `__unwind_info` for dylibs, plus a flat table for relocatable objects. The May 2025 limitation ("no compact unwind info") no longer applies at this revision.
- It also writes `LC_UUID` (a content hash, so deterministic), `LC_ID_DYLIB` and `LC_RPATH`.
- Limitations: none found in the source at this revision. Not verified: how App Store processing treats the ad-hoc signature after zsign re-signs it, and whether the dylib passes `vtool`/`codesign -v` style checks. Spike B and the device test will tell.

### 6e. The engine build and what would need to change

- `engine/src/flutter/lib/snapshot/BUILD.gn`:
  - The iOS and macOS gen_snapshots (`create_macos_gen_snapshots`, `create_arm_gen_snapshot`, the universal binary via `lipo`) are wired only under `host_os == "mac"`.
  - There is already a generic branch: "For other host OSes, build gen_snapshot directly" → `$dart_src/runtime/bin:gen_snapshot($host_toolchain)`.
  - **This file needs no change.**
- The real blockers are elsewhere:
  - `engine/src/build/config/BUILDCONFIG.gn`: `is_ios` selects `host_toolchain = //build/toolchain/mac:clang_$host_cpu` and a mac default toolchain.
  - `engine/src/build/toolchain/mac/BUILD.gn:5`: `assert(host_os == "mac")`.
  - `engine/src/flutter/tools/gn`: `setup_apple_sdks()` reads `flutter/prebuilts/SDKs` and `Platforms`, which a Mac checkout provides.
  - So `gn gen` with `target_os="ios"` fails on Linux before anything is built.
- **Dart's own build scripts.** `tools/gn.py` accepts `--os=ios` but refuses it unless the host is macOS: "Target os ios is only supported on macOS" (`tools/gn.py:403`). Cross archs are `arm64`, `arm64c`, `simarm64`, etc. There is no `xarm64` at this revision. A plain `--arch=arm64` with a non-host `--os` is the cross gen_snapshot pattern (as used for Android).

**Minimal change proposed (not applied).** Build on Linux with GN `target_os="linux"`, `target_cpu="arm64"` and `dart_target_arch="arm64"`, which is the same shape as the Linux-host Android gen_snapshot. Add one GN arg that overrides only the Dart target-OS defines:

```gn
# runtime/runtime_args.gni (declare_args)
dart_target_os_override = ""   # "ios" to build an iOS-targeting gen_snapshot on a non-Mac host

# runtime/BUILD.gn, config("dart_os_config"), checked first
if (dart_target_os_override == "ios") {
  defines += [ "DART_TARGET_OS_MACOS", "DART_TARGET_OS_MACOS_IOS" ]
} else if (target_os == "android") {
  ...
```

Then build only `runtime/bin:gen_snapshot` in the host toolchain, in product mode (`dart_runtime_mode="release"`, `dart_use_compressed_pointers=false`). This avoids the Mac toolchains entirely, because nothing is built for `target_os="ios"`. The same override works in the standalone Dart tree (calling `gn gen` with args, which skips the `tools/gn.py` check) and in the engine tree.

| Option | Checkout | Disk (estimate) | Build time (estimate, 12 vCPU) | Patch |
| --- | --- | --- | --- | --- |
| P1a: standalone Dart SDK at `dart_revision` | `gclient sync` of dart-lang/sdk with its deps (clang, sysroot, third_party) | 6–10 GB source + toolchains, 1–2 GB out | 10–25 min for `gen_snapshot` only | 2 GN files, about 10 lines |
| P1b: Flutter engine tree at 3.47.7 | `gclient sync` of the engine (`engine/src`, includes Dart, Skia, etc.) | 20–30+ GB | 15–30 min for `gen_snapshot` only, but `gn gen` has to evaluate the whole engine graph | Same Dart patch, plus `tools/gn` arguments; avoid `target_os="ios"` |

Both estimates are unmeasured. Both need approval (gclient sync; possibly over 3 GB in one download).

## Emulation fallback (reading only)

- **The prebuilt gen_snapshot is a macOS executable.** `gen_snapshot_arm64` is a universal Mach-O with two slices, `x86_64` (7,072,096 bytes) and `arm64` (6,891,920 bytes). It cannot run on Linux without a macOS userland emulator.
- **Darling.** Its README describes "a Mach-O binary loader and a userspace kernel server (darlingserver)". Current versions document no kernel module, and it says "Official packages for some distributions are available under releases". It does not mention WSL2. `docs.darlinghq.org` was unreachable from this session. Running gen_snapshot under Darling probably only needs basic libSystem, which is plausible but unverified. Darling is a heavy dependency with its own release cadence, and it is unvetted for WSL2.

## Candidate paths

| Path | Description | Cost | Risk | Maintenance per Flutter release |
| --- | --- | --- | --- | --- |
| **P1** | Build gen_snapshot from source on Linux | P1a: one gclient sync plus a ~10-line GN patch. P1b: a much larger checkout | Medium: output equivalence with Apple-built gen_snapshot must be proven; Flutter's engine may set extra GN args that change codegen | Low if the patch keeps applying: rebuild at the new `dart_revision` (CI job, about 20 min) |
| **P2** | Run the macOS gen_snapshot under emulation (Darling) | Install and validate Darling on WSL2 | High: unvetted on WSL2, large dependency, opaque failures | Low per release (reuses Google's binaries), high one-time and ongoing environment risk |
| **P3** | Remote macOS fallback | macOS CI runner runs the official `gen_snapshot_arm64` (or the whole build) | Low technically; needs network, CI minutes, and a Mac in the loop | None per release; contradicts "no Mac" for the release lane, but it is already the plan's fallback |

## Recommended phase A1 plan

1. **P1a, the standalone Dart SDK at `04bcd103…c822`.**
   - Fetch with `gclient sync` (needs approval).
   - Apply the `dart_target_os_override` patch.
   - Run `gn gen out/ProductXARM64Ios` with `target_os="linux" target_cpu="arm64" dart_target_arch="arm64" dart_runtime_mode="release" dart_target_os_override="ios"`.
   - Run `ninja -C ... runtime/bin:gen_snapshot`.
   - Estimate: 6–10 GB disk and 30–60 min including the sync (unmeasured). The build itself may exceed 20 minutes, which needs approval.
2. **Check the result.**
   - The binary must be an ELF x86-64 executable.
   - Its features fragments must include ` ios` and ` no-compressed-pointers`, and its snapshot hash must equal `0451907c2eaa8467e848c0067bfe8ed4`.
3. **Produce `App.framework/App`.**
   - Run step 2 of the pipeline above on the counter `app.dill`.
   - Check with `llvm-objdump --macho --private-headers`: a dylib with `LC_BUILD_VERSION` platform iOS, minos 15.0, `LC_ID_DYLIB @rpath/App.framework/App`, both rpaths, `LC_ENCRYPTION_INFO_64` and `LC_CODE_SIGNATURE`.
   - Confirm the full features string in the snapshot data.
4. **Oracle diff, which settles equivalence.**
   - On a GitHub macOS runner (P3 used only as a test oracle), run the official `gen_snapshot_arm64` from the same engine revision on the same `app.dill` with the same flags.
   - Because of `--deterministic`, the expectation is a byte-identical `App` (`LC_UUID` is a content hash). If it differs, diff the Mach-O sections to find the GN-arg mismatch.
   - Cost: one workflow, a few minutes of macOS runner time.
5. If steps 2–4 pass, GREEN pending spike B (load on device). If the build fails because of host/target assumptions in Dart code, assess the patch size: small means still GREEN, per-release churn means AMBER.

## Open questions

- Which GN args does the Flutter engine set for Dart in an iOS release build that a standalone Dart build does not? Examples: `dart_runtime_mode`, `exclude_kernel_service`, `dart_support_perfetto`, `dart_lib_export_symbols`, LTO. Some could change codegen or the features string. The oracle diff in step 4 answers this empirically. Reading `engine/src/flutter/BUILD.gn` and `//flutter/common/config.gni` answers it on paper.
- Does the Dart standalone `gclient sync` on Linux pull anything Mac-only that we would need? Expected no.
- Is the ad-hoc `LC_CODE_SIGNATURE` written by gen_snapshot fine to re-sign with zsign, the same way Xcode re-signs it with `codesign --force`?
- `dsymutil` and `strip -x`: do we ship stripped binaries (App Store size) and keep a dSYM (crash symbolication)? The tools exist on Linux (xtool toolset `dsymutil`, `llvm-strip`). It needs a decision, not research.
- Darling on WSL2 stays unexplored unless P1 fails.

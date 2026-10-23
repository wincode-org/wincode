# Spike D: store parity of the Windows-built bundle

Status: done, 2026-10-21. **Result: every difference left between our bundles and Xcode's is either accepted for now or comes from tools Xcode has and we don't.** Both apps still run on the iPhone. No product code: that waits for ADR-0009 and ADR-0010.

## Question

How close can the Windows-built bundle get to the Xcode-built one, measured with `tools/ipa-diff` against the reference run (`oracle-reference-builds`, run 39513689791: Xcode 26.6, iPhoneOS 26.5 SDK)?

## Inputs

| Item | Value |
| --- | --- |
| Apps | Spike E's `counter` and `hooks_app` (`spikes/e-native-build-hooks/make_apps.sh`), Flutter 3.47.7 |
| Ours | Spike E's output for each app (App.framework, native-asset frameworks), rebuilt by `spikes/d-store-parity/build.sh` |
| Reference | The Xcode-built `Runner.app` of each app from run 39513689791, copied to a local folder outside the repo, never uploaded (GitHub deletes artifacts after 7 days) |
| Device | iPhone 15, iOS 27.0.1, development signing by xtool 1.22.2 |

## Result: `ipa-diff` lines per category

Each step includes the earlier ones.

| Step | Info.plist | Layout | Load commands | Entitlements | Resources |
| --- | --- | --- | --- | --- | --- |
| hooks app, baseline (spike E) | 23 | 9 | 13 | 1 | 16 |
| a. SDK stamp | 23 | 9 | 13 | 1 | 16 |
| b. runner hygiene | 23 | 9 | 12 | 1 | 16 |
| c. Info.plist | 12 | 9 | 12 | 1 | 16 |
| d. assets | **12** | **8** | **12** | **1** | **13** |
| counter, baseline | 22 | 8 | 10 | 0 | 15 |
| counter, after d | **11** | **7** | **9** | **0** | **12** |

Step a changes a value inside a line, so the counts stay the same: the executable's `sdk 15.0` becomes `sdk 26.5`. The line stays only because the linkers differ (lld against Apple's ld).

## The fixes

### a. SDK stamp

- **Why 15.0:** xtool links the app in a generated builder package (`xtool/.xtool-tmp`), through Swift Build and `swiftc -target arm64-apple-ios15.0 -sdk …/iPhoneOS26.5.sdk` with lld. The object files record SDK 26.5, but the Swift driver hands the linker the deployment target as the SDK version, so the executable says `sdk 15.0`.
- **Fix: the linker's own flag.** `-Xlinker -platform_version -Xlinker ios -Xlinker 15.0 -Xlinker 26.5` in the runner's `linkerSettings`. SwiftPM passes it on to the final link, and the executable then records `minos 15.0 sdk 26.5`.
  - The minimum comes from the runner's `Package.swift`, the SDK version from the SDK's `SDKSettings.json`.
  - `-target-sdk-version` doesn't work at link time ("unknown argument"), and no Mach-O patching is needed.

### b. Runner hygiene

- **Release configuration** (`xtool dev build -c release`) removes the `.build/…/PackageFrameworks` rpath, which only debug builds add.
- **Swift Build adds three rpaths of its own** to the link, ahead of anything a package can add: `/usr/lib/swift`, `@loader_path` and the swiftly toolchain's `lib/swift-6.2/iphoneos`. `-no-toolchain-stdlib-rpath` doesn't remove them.
- **So the spike removes them after linking,** before signing (`bundle_fix.py rpaths`). It keeps `/usr/lib/swift` and `@executable_path/Frameworks`, Xcode's exact two.
- **Linking only Foundation and UIKit, like Xcode's runner, would need the runner template to change.** Not done here.
  - Use the UIKit app lifecycle (an `@main` app delegate with `FlutterViewController`) instead of a SwiftUI `App`.
  - Use no `async` code, so `libswift_Concurrency` isn't linked.
  - Drop the `SwiftUI` import.

### c. Info.plist

- **The app's own `ios/Runner/Info.plist`** is merged over the runner's (`bundle_fix.py plist`), with `$(DEVELOPMENT_LANGUAGE)`, `$(EXECUTABLE_NAME)`, `$(PRODUCT_BUNDLE_IDENTIFIER)`, `$(PRODUCT_MODULE_NAME)`, `$(FLUTTER_BUILD_NAME)` and `$(FLUTTER_BUILD_NUMBER)` substituted. An unknown variable stops the build.
- **That brings in Flutter's template keys and the app's iPad orientations.** The bundle ID stays the runner's, so no new App ID.
- **Keys that point at things the runner doesn't ship are dropped:** `UIMainStoryboardFile`, `UILaunchStoryboardName` and the `SceneDelegate` scene configuration.
- **SDK keys, read from the Darwin SDK's own files:**

| Key | Value | Source |
| --- | --- | --- |
| `DTSDKName` | iphoneos26.5 | `SDKSettings.json` `CanonicalName` |
| `DTPlatformName` | iphoneos | `SDKSettings.json` `DefaultProperties.PLATFORM_NAME` |
| `DTPlatformVersion` | 26.5 | `iPhoneOS.platform/Info.plist` |
| `DTSDKBuild` | 23F81a | the SDK's `System/Library/CoreServices/SystemVersion.plist` |
| `DTPlatformBuild` | 23F81a | the same file: xtool's SDK keeps no platform `version.plist` |

- **Not written**, because they would claim a build machine we don't have: `DTXcode`, `DTXcodeBuild`, `DTCompiler`, `BuildMachineOSBuild`.

### d. Assets

- **`.last_build_id`** is no longer shipped.
- **Shaders:** `flutter build bundle` compiles them for Android whatever `--target-platform` says. flutter_tools' `CopyFlutterBundle` calls `copyAssets` with `TargetPlatform.android` (`build_system/targets/common.dart`), so `ink_sparkle.frag` and `stretch_effect.frag` held SkSL, SPIR-V and GLES instead of Metal. Recompiled with flutter_tools' iOS `impellerc` arguments (`--runtime-stage-metal --iplr`), they are **byte-identical to Xcode's**.
- **The native-asset manifest's content is identical** to Xcode's; only the JSON formatting differs.

## Differences left

**Accepted for now:**
- **No icon:** `Assets.car`, `CFBundleIcons`, `CFBundleIcons~ipad` and the loose `AppIcon*.png` files (the `Assets.car` track).
- **No storyboards:** `Base.lproj/*.storyboardc`, `UIMainStoryboardFile`, `UILaunchStoryboardName`, the scene configuration. We ship `UILaunchScreen` instead.
- **Framework signing:**
  - Xcode signs each framework without entitlements; ours ship unsigned.
  - xtool's development signing adds the app's entitlements to every framework, and iOS logs an AMFI notice for each.
  - Store signing must leave entitlements off frameworks (ADR-0009).

**Expected, from tools we don't have:**
- **Xcode-only keys:** `DTXcode`, `DTXcodeBuild`, `DTCompiler`, `BuildMachineOSBuild`.
- **lld instead of Apple's ld:** chained fixups and an exports trie instead of `LC_DYLD_INFO_ONLY` in `objective_c`, and no `LC_SOURCE_VERSION`.
- **The runner itself:** a different executable name and bundle ID, and SwiftUI and concurrency links (see b).
- **Smaller extras Xcode writes:** `PkgInfo`, and the template's `AppFrameworkInfo.plist` copied to the bundle root.

**From the asset-bundle stopgap** (spike E, finding 2):
- `NOTICES.Z` lacks the hook packages' licences.
- `MaterialIcons-Regular.otf` isn't tree-shaken against the app's own code.

## On the iPhone

Both apps installed with xtool through `spikes/b-device/install.sh`, with no revoke prompt.
- The counter app starts and counts.
- The hooks app shows its documents folder, and the device log has `flutter: spike-e documents: /var/mobile/Containers/Data/Application/<uuid>/Documents`.
- The SDK stamp and the merged Info.plist didn't stop either app.

## Reproduce

After spike E's `assemble.sh` for each app, in WSL2:

```bash
bash spikes/d-store-parity/build.sh ~/spikes/spike-e/hooks_app ~/spikes/spike-e/out/hooks_app \
  ~/spikes/spike-d/out/hooks_app <Xcode-built reference .app folder>
```

It writes a copy of the `.app` after each step, an unsigned `.ipa` and one `ipa-diff` report per step.

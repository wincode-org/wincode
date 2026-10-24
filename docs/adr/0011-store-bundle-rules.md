# 0011. Store bundle rules

- Status: Proposed
- Date: 2026-10-24

## Context

The pure-Windows lane (ADR-0008) builds the store bundle without Xcode, and Apple judges only the bundle. Each part that Xcode would write must be the same as Xcode's, true but different, or a known gap. These rules come from evidence only. Each one says what we decided, what shows it, and what would make us reverse it.

**Sources:**
- **Oracle run 39513689791** (`oracle-reference-builds`, 2026-10-20): Xcode 26.6 (17F113), iPhoneOS 26.5 SDK, macOS 26.6.2 (25G83). Its artifacts are kept in a local folder outside the repo, never uploaded: the Xcode-built counter and hooks apps, their dumps (`info-plists.txt`, `otool-l.txt`, `codesign-entitlements.txt`), the build logs and the icon sample.
- **PR #16:** `docs/formats/assets-car-app-icon.md`, actool's output for a one-icon catalog (2026-10-21).
- **Spike D, PR #17:** `docs/spikes/spike-d-store-parity.md`, our bundle against Xcode's, fix by fix (2026-10-21).
- **Spike C:** `docs/spikes/spike-c-store-acceptance.md`, C1's recorded upload result (2026-10-23).
- **Apple Developer, "Upcoming Requirements", section "SDK minimum requirements"** (read 2026-10-21).
- **Apple Developer Documentation, "UILaunchScreen",** with its `UIColorName` and `UIImageName` pages (read 2026-10-21).

The quotes from both Apple pages were checked again on 2026-10-24.

## Decision

### 1. SDK stamp

- **Decision:** the runner is linked with `-Xlinker -platform_version -Xlinker ios -Xlinker <min> -Xlinker <sdk>` in its link settings.
  - `<min>` is the app's deployment target, the same value `MinimumOSVersion` gets.
  - `<sdk>` is `Version` from `SDKSettings.json` in the user's own SDK, built from their Xcode.xip.
  - No Mach-O is patched.
- **Evidence:**
  - **Without the flag,** xtool's link records the deployment target as the SDK, so the executable says `sdk 15.0` (spike D, a).
  - **With it,** the executable records `minos 15.0 sdk 26.5`, the same as Xcode's runner. Xcode links its runner with `-target arm64-apple-ios15.0` against `iPhoneOS26.5.sdk` (oracle run, `otool -l` and build log).
  - **No compiler-side alternative:** `-target-sdk-version` is refused at link time, with "unknown argument" (spike D, a).
  - **The other binaries already match Xcode's:**
    - `App.framework` says `sdk 15.0` in both bundles.
    - Google's `Flutter.framework` says `sdk 26.2` in both.
    - The hooks app's `objective_c`, linked by our clang, says `sdk 26.5`, as Xcode's does.
    - Sources: the oracle run's dumps and spike D's output.
  - **Apple:** uploads "must be built with Xcode 26 or later using an SDK for iOS 26" (Upcoming Requirements, since April 28, 2026). C1 carried `sdk 26.5`, and Apple processed it as `VALID` with no message (spike C, 2026-10-23).
- **Reverse if:** the linker or Swift Build stops passing the flag through, or Apple's validation reads the SDK from somewhere the flag doesn't set. The stamp then moves to another link-time setting; patching the Mach-O would need a new decision.

### 2. Info.plist

- **Decision:**
  - **Merge:** the app's own `ios/Runner/Info.plist` is merged over the runner's.
    - Each `$(NAME)` is replaced by its value from the project's build settings. Spike D used `DEVELOPMENT_LANGUAGE`, `EXECUTABLE_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`, `PRODUCT_MODULE_NAME`, `FLUTTER_BUILD_NAME` and `FLUTTER_BUILD_NUMBER`.
    - An unknown variable stops the build: `unknown Info.plist variable $(NAME)`.
  - **Dropped:** the keys that point at things the bundle doesn't ship, namely `UIMainStoryboardFile`, `UILaunchStoryboardName` and the scene configuration's storyboard (rule 3).
  - **Written:** the five SDK keys, read from the user's own SDK files.

    | Key | Read from | Ours and Xcode's (run 39513689791) |
    | --- | --- | --- |
    | `DTSDKName` | `SDKSettings.json`, `CanonicalName` | `iphoneos26.5` |
    | `DTPlatformName` | `SDKSettings.json`, `DefaultProperties.PLATFORM_NAME` | `iphoneos` |
    | `DTPlatformVersion` | `iPhoneOS.platform/Info.plist` | `26.5` |
    | `DTSDKBuild` | the SDK's `System/Library/CoreServices/SystemVersion.plist`, `ProductBuildVersion` | `23F81a` |
    | `DTPlatformBuild` | the same file, because xtool's SDK has no platform version file | `23F81a` |

  - **Checked:** the reference's `DTPlatformBuild` is `23F81a`. That equals its `DTSDKBuild` and the value we read.
  - **Never faked:** `DTXcode`, `DTXcodeBuild`, `DTCompiler` and `BuildMachineOSBuild`. Xcode wrote `2660`, `17F113`, `com.apple.compilers.llvm.clang.1_0` and `25G83`, which describe an Xcode and a Mac that never built our app.
- **Evidence:**
  - **The merge works on the device:** it brought in Flutter's template keys and the app's iPad orientations, and both apps ran on the iPhone (spike D, c).
  - **Apple's rule names Xcode:** uploads "must be built with Xcode 26 or later using an SDK for iOS 26" (Upcoming Requirements, since April 28, 2026). So the Xcode keys probably matter. C1 passed without the four Xcode keys at upload and processing, but App Review has not been tested.
  - **C1 had none of the four Xcode keys:** it carried the five SDK keys only, and Apple processed it as `VALID` with no errors, warnings or infos (spike C, 2026-10-23). TestFlight lists build 1 as Ready to Submit in the Internal group and the tester installed it on an iPhone; no Apple warning email reached the uploader's inbox in the first hour; the account holder's inbox is not checked yet.
- **Reverse if:**
  - **Spike C shows Apple requires the Xcode keys:** a refusal, or an error, warning or email that names them. The pure-Windows lane then can't meet the rule honestly, and the cloud Mac lane stays the only store lane (ADR-0008).
  - **App Review refuses a build without the Xcode keys:** this also reverses the decision, with the same result.
  - **An Xcode reference shows `DTPlatformBuild` different from `DTSDKBuild`:** the platform build is then read from the platform's own version file, which the SDK build must keep.

### 3. Runner

- **Decision:**
  - **Storyboard-free:** the bundle ships no `.storyboardc`. The launch screen is `UILaunchScreen`, and the runner creates the `FlutterViewController` in code.
  - **Target: a UIKit app delegate.** The runner moves from spike B's SwiftUI `App` to the UIKit app lifecycle: an `@main` app delegate like Flutter's template (`FlutterAppDelegate`), with no `async` code.
  - **No build-machine rpaths:** the executable carries exactly Xcode's two rpaths, `/usr/lib/swift` and `@executable_path/Frameworks`.
    - The runner is a release build, because debug builds add a `PackageFrameworks` path.
    - Swift Build adds rpaths of its own, one of them the build machine's toolchain folder. They are removed after linking and before signing.
  - **Refused in v1:** apps that need real storyboards. The exact check is below.
- **Evidence:**
  - **Xcode's runner** links Foundation, `libobjc`, `libSystem`, `libc++`, `libswiftCore`, `libswiftFoundation`, `libswiftUIKit` and Flutter: no SwiftUI and no Swift concurrency. Its rpaths are `/usr/lib/swift` and `@executable_path/Frameworks`, passed as `-Xlinker -rpath` (oracle run, `otool -l` and build log).
  - **Spike D's runner** is spike B's SwiftUI app. It links SwiftUI and Swift concurrency on top, and only a UIKit app delegate with no `async` code drops them (spike D, b).
  - **Flutter 3.47.7's template app delegate is already UIKit:** `@main @objc class AppDelegate: FlutterAppDelegate` (spike D's test apps).
  - **`UILaunchScreen` works on the device:** spike D shipped it instead of storyboards, and both apps ran on the iPhone.
  - **Apple's UILaunchScreen pages** (iOS 14.0 and later):
    - The key sets up the launch screen "in a way that doesn’t rely on storyboards".
    - `UIColorName` must be "the name of a color in your asset catalog", and `UIImageName` "the name of an image in your asset catalog".
    - With no colour, "the system uses a default of systemBackground".
  - **So the `Assets.car` track must cover colour sets and image sets, not only the app icon.**
    - This is to be confirmed by the oracle sample, which gains a colour set and an image set named by `UILaunchScreen` for this.
    - C1's launch storyboard names `LaunchImage`, which the icon sample's `Assets.car` doesn't have (spike C).
    - Xcode's `Assets.car` for the counter app does contain the name `LaunchImage`, Flutter's template image set (oracle run).

**The storyboard check** runs when the builder reads the project, before anything compiles.

- **Inputs:** it parses, as XML, every storyboard that the app's Info.plist names (`UIMainStoryboardFile`, each scene's `UISceneStoryboardFile`, `UILaunchStoryboardName`), from `ios/Runner/`.
- **A main storyboard passes** when:
  - it has exactly one element with `sceneMemberID="viewController"`;
  - that element is a `viewController` with `customClass="FlutterViewController"`;
  - its view has no `subviews`;
  - the file has no `connections` element (outlets, actions or segues).
- **A launch storyboard passes** when:
  - it has exactly one element with `sceneMemberID="viewController"`, a `viewController` with no `customClass`;
  - it has no `connections` element;
  - its view has no subviews, or one `imageView` with `contentMode="center"`.
- **What a passing launch storyboard becomes:**
  - **The image:** it must be an image set in the app's catalog, and it becomes `UIImageName`.
  - **The background colour:**
    - a named colour becomes `UIColorName`;
    - `systemBackgroundColor`, or no colour, leaves `UIColorName` out;
    - a literal colour becomes a colour set that the builder adds to the compiled catalog;
    - any other system colour fails.
- **Always refused:**
  - any other `.storyboard` or `.xib` file under `ios/Runner`;
  - an `NSMainNibFile` key in Info.plist.
- **Flutter's template passes:** one `FlutterViewController` in `Main.storyboard`, and one view controller with one centred `LaunchImage` on white in `LaunchScreen.storyboard`.
- **Error text,** one per failure, with `<file>` relative to the app:

  ```
  error: <file>: <reason>.
  winCode v1 builds iOS apps without storyboards (ADR-0011). Main.storyboard may hold only Flutter's
  FlutterViewController, and the launch screen one centred image on a background colour.
  Simplify the storyboard, or build this app in the cloud Mac lane: wincode ship --lane mac
  ```

  | Failure | `<reason>` |
  | --- | --- |
  | Not one view controller | `has <n> view controllers, not 1` |
  | Main storyboard, another class | `its view controller is <class>, not FlutterViewController` |
  | Main storyboard, views inside | `its view has subviews` |
  | Launch storyboard, custom class | `its view controller has the custom class <class>` |
  | Launch storyboard, too many views | `its view holds <n> subviews, not 0 or 1` |
  | Launch storyboard, not an image | `its view holds a <element>, not an image view` |
  | Launch storyboard, image layout | `its image view's content mode is <mode>, not center` |
  | Launch storyboard, image outside the catalog | `its image <name> is not in the app's asset catalog` |
  | Launch storyboard, system colour | `its background is the system colour <name>` |
  | Outlets, actions, segues | `has outlets, actions or segues` |
  | Any other storyboard or nib file | `winCode v1 doesn't compile storyboards or nib files` |
  | `NSMainNibFile` (`<file>` is `ios/Runner/Info.plist`) | `NSMainNibFile names a nib file` |

- **Reverse if:**
  - **Apple refuses a storyboard-free bundle or its launch screen** (C2).
  - **Many apps fail the check,** for example launch storyboards with two image views, which some splash-screen packages write. v1 then translates that shape too, or storyboards get a clean-room compiler like `Assets.car`.
  - **A storyboard-free UIKit runner can't start Flutter's template app,** whose scene configuration names `Main` as the scene's storyboard (C2's install).

### 4. Frameworks

- **Decision:** every embedded framework is signed with the Apple Distribution certificate and no entitlements: `App.framework`, `Flutter.framework`, and plugin and native-asset frameworks. Only the app's main executable gets entitlements (ADR-0009).
- **Evidence:**
  - **Xcode's frameworks carry signatures with no entitlements:** `App.framework`, `Flutter.framework` and `objective_c.framework` (oracle run, `codesign-entitlements.txt`). The app itself was built with `--no-codesign`, so the run shows nothing about the app's own signature.
  - **Entitlements on frameworks cost an AMFI notice:** xtool's development signing gives every framework the app's entitlements, and iOS logs that notice for each one (spike D; spike E, finding 6).
  - **zsign gives entitlements only to main executables** (`archo.cpp`; spike C, step 5).
  - **C1 was signed this way and processed:** its frameworks read back with no entitlements and its executable with four keys, and Apple processed it as `VALID` (spike C, 2026-10-23).
- **Reverse if:** Apple's validation or email flags a framework's signature, or an Xcode distribution-signed reference shows a framework with entitlements.

### 5. Shaders

- **Decision:** the builder recompiles every shader in `flutter_assets/shaders` for iOS, because `flutter build bundle` compiles them for Android.
  - **How:** after `flutter build bundle`, it finds the source `.frag` of each compiled shader and runs the engine's Linux `impellerc` with flutter_tools' iOS arguments:

    ```
    --runtime-stage-metal --iplr --sl=<shader> --spirv=<scratch file> --input=<source .frag>
    --input-type=frag --include=<source folder> --include=<impellerc folder>/shader_lib
    ```

    The output replaces the Android one, and the SPIR-V scratch file is deleted.
  - **Sources:** Flutter's own shaders come from the Flutter SDK (`packages/flutter/lib/src`), and the app's own from the `shaders:` list in its `pubspec.yaml`.
- **Evidence:**
  - flutter_tools' `CopyFlutterBundle` calls `copyAssets` with `TargetPlatform.android`, whatever `--target-platform` says. So `ink_sparkle.frag` and `stretch_effect.frag` held SkSL, SPIR-V and GLES instead of Metal (spike D, d).
  - Recompiled this way, they are byte-identical to Xcode's (spike D, d).
- **Open check: an app with its own shader.** Spike D looked for sources only in Flutter's package, so app shaders aren't covered yet.
  - **The test:** a test app with one `.frag` in `flutter: shaders:`, built by Xcode in the oracle workflow and by winCode.
  - **Passes when:** the two compiled files are byte-identical, and the shader draws on the iPhone.
- **Reverse if:**
  - **flutter_tools starts compiling shaders for the target platform:** the recompile step is dropped.
  - **impellerc's output stops matching Xcode's:** the builder follows that Flutter release's arguments.

### 6. App entitlements

- **Decision:** the app's executable is signed with its own `.entitlements` file merged with `application-identifier`, `com.apple.developer.team-identifier`, `get-task-allow` = false and its own keychain group.
  - **Checked:** every key and value is checked against the provisioning profile, and signing stops if the profile doesn't allow one.
  - **Frameworks:** they get none (rule 4).
- **Evidence:** C1's four keys were accepted (spike C, 2026-10-23).
- **Open:** an app with Sign in with Apple, tested in the hybrid lane (Xcode builds the unsigned app on a hosted Mac runner; the app is signed and uploaded as in C1).
- **Reverse if:** Apple or iOS flags an entitlement.

## Known gaps, and how spike C tests each

| Gap | C1 (uploaded 2026-10-23) | C2 |
| --- | --- | --- |
| App icon | Xcode-made `Assets.car`, and `CFBundleIcons` from actool's partial Info.plist (the icon sample) | winCode's own `Assets.car` |
| Launch screen | Xcode's compiled `LaunchScreen.storyboardc`, named by `UILaunchStoryboardName`. Its `LaunchImage` isn't in the icon sample's `Assets.car` | `UILaunchScreen` only, with its colour and image in winCode's `Assets.car`; no storyboards |
| Xcode keys | Without: none of the four | With: only a bundle that a Mac really built carries them honestly. The "with the keys" control is the hybrid lane (Xcode builds the unsigned app on a hosted runner, the app is signed and uploaded as in C1), not a separate run |

C1 so far: processed `VALID`, with no errors, warnings or infos. TestFlight lists build 1 as Ready to Submit in the Internal group and the tester installed it on an iPhone; no Apple warning email reached the uploader's inbox in the first hour; the account holder's inbox is not checked yet.

## Open questions

| Question | Who answers |
| --- | --- |
| Does C1 reach "Ready to Submit (Apple's label for a build testers can install)" with no ITMS warning in Apple's email, and install and run from TestFlight? | Spike C, steps 9 to 11 |
| Are the Xcode keys required at any stage spike C reaches? | Spike C, C1 and the "with" control |
| Does a storyboard-free bundle with winCode's `Assets.car` pass the same way and start on the iPhone? | Spike C, C2 |
| May builds made with the SDK on a PC be uploaded, and what must winCode tell its users? Until this is answered, the cloud Mac lane stays the default store lane (ADR-0008) | The legal review (`docs/PLAN.md`, "Licence and account risk") |
| How does actool store a colour set and an image set, and do `UILaunchScreen`'s names find them? | The `Assets.car` spec in `docs/formats/`, from the oracle sample's new sets |

## Consequences

- **The store bundle matches Xcode's wherever we have the tools and true values:** the SDK stamp, the SDK keys, rpaths, framework signatures and shaders. The remaining differences are listed in spike D and above.
- **The `Assets.car` track grows** from the app icon to colour sets and image sets.
- **The runner template changes** from spike B's SwiftUI app to a UIKit app delegate.
- **Apps with real storyboards can't use the pure-Windows lane in v1.** The error sends them to the cloud Mac lane.
- **If spike C shows that the Xcode keys are required,** pure-Windows store builds stop, and the cloud Mac lane stays the only store lane.

## Alternatives considered

- **Patch `LC_BUILD_VERSION` after linking:** it works, but it edits the binary by hand when the linker has a flag for it.
- **Copy the Xcode keys from a reference build:** they would claim an Xcode and a Mac that never built the app.
- **Compile storyboards:** it needs `ibtool`, an Xcode tool winCode doesn't run, or a clean-room storyboard compiler. That is too much for v1, while `UILaunchScreen` covers Flutter's template.
- **Keep spike B's SwiftUI runner:** it links SwiftUI and Swift concurrency, and Xcode's runner links neither.
- **Give frameworks the app's entitlements, as xtool's development signing does:** iOS logs an AMFI notice for each one.
- **Ship the shaders as `flutter build bundle` writes them:** they hold Android formats, not Metal.

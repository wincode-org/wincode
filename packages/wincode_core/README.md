# wincode_core

Dart library: Flutter-to-SwiftPM project translator, plist handling, IPA packaging.

Status: started. What is here so far is the iOS flavor settings (ADR-0011 rules 2 and 6), `flutter_assets` (rule 5) and the Dart code (ADR-0004), `docs/PLAN.md` steps 1, 3, 4 and 7.

| Part | What it does |
| --- | --- |
| `parsePlist`, `parsePlistBytes`, `writePlist`, `writePlistBinary` | Read XML and binary property lists, write XML ones with sorted keys, and binary ones laid out as Core Foundation lays them out, so the same data gives the bytes Xcode writes |
| `parseOpenStep` | Reads `project.pbxproj` |
| `readXcconfig` | Reads an `.xcconfig` file with its `#include` chain, and conditions such as `[sdk=iphoneos*]` |
| `resolveBuildSettings` | Layers Xcode's defaults, the project's and the target's settings and xcconfig files, for one configuration such as `Release-<flavor>` |
| `buildInfoPlist` | The app's `Info.plist` template with its `$(NAME)` variables replaced, the keys Xcode derives from the settings, the five SDK keys, and no storyboard keys; never Xcode's four (`DTXcode`, `DTXcodeBuild`, `DTCompiler`, `BuildMachineOSBuild`) |
| `buildEntitlements` | The app's `.entitlements` merged with `application-identifier`, the team identifier, `get-task-allow` false and the app's keychain group |
| `readIosFlavor` | All of the above for `--flavor` and a build mode |
| `checkFlutterSdkLineEndings` | A `wincode doctor` check: warns when the Flutter SDK was checked out with CRLF line endings |
| `buildFlutterAssets` | `flutter_assets` for an iOS release build on a host that is not a Mac: `flutter assemble copy_flutter_bundle` with the flavor, then every shader compiled again for iOS with the engine's `impellerc` and flutter_tools' iOS arguments |
| `buildKernel` | The app's Dart code as a kernel file for an iOS release build: `flutter assemble kernel_snapshot_program` with the flavor and Dart defines |
| `genSnapshotArguments`, `buildAppBinary` | The arguments flutter_tools gives `gen_snapshot` for iOS (Flutter 3.47.5, `--snapshot_kind=app-aot-macho-dylib`), and a run of a given `gen_snapshot` in a work folder |
| `finishAppBinary`, `wrapInFat` | The steps flutter_tools runs after `gen_snapshot` for a release build: the dSYM (`dsymutil`), `strip -x` (`llvm-objcopy --discard-all`) and the universal container that `lipo` makes for one architecture |
| `buildSwiftPackage`, `swiftBuildCommand` | Builds one product of a SwiftPM package (a plugin) for iOS arm64 as a static library, the way xtool does with Swift 6.4: the `swiftbuild` build system, the Darwin SDK's toolset and platform folder. It finds `lib<product>.a` and the resource bundles. Nothing is linked into an app |
| `wslRunner`, `toWslPath` | A `RunProcess` that runs commands inside WSL2, and the path conversion for it |
| `buildNativeAssetFramework`, `nativeAssetFrameworkName`, `nativeAssetFrameworkInfoPlist`, `nativeAssetsManifest`, `setInstallName` | Turns the dynamic library a Dart build hook wrote (ADR-0010) into the framework flutter_tools makes for iOS: `<name>.framework/<name>` with its local symbols removed (`llvm-objcopy`), the install name `@rpath/<name>.framework/<name>` set by an in-place Mach-O edit, and flutter_tools' `Info.plist`. `nativeAssetsManifest` writes the `ios_arm64` entry of `NativeAssetsManifest.json`. The hook itself is run by spike E's `run_hooks` |
| `writeRunnerPackage`, `buildRunner`, `SwiftPlugin` | The storyboard-free runner (ADR-0011 rule 3): writes the generated plugin package and a runner package under a work folder, and builds the runner for iOS arm64. The runner package compiles the app's own `AppDelegate.swift` and `SceneDelegate.swift` unchanged, with a registrant that names only the plugins given and a scene delegate base that creates the window and the `FlutterViewController` in code. It is linked with the SDK stamp (`-platform_version ios <target> <SDK>`) and `@executable_path/Frameworks`, then `removeRpaths` takes out the build machine's paths |
| `generatedPluginPackageManifest`, `generatedPluginRegistrant`, `runnerPackageManifest`, `sceneDelegateBase`, `sdkVersion` | The pieces `writeRunnerPackage` writes: `FlutterGeneratedPluginSwiftPackage/Package.swift` as flutter_tools writes it on a Mac (a static library whose target depends on the product of each plugin), the registrant in Swift, the runner's `Package.swift`, and the scene delegate base |
| `removeRpaths` | Mach-O edit: takes the `LC_RPATH` commands that are not wanted out of a 64-bit file, moving the later commands up |
| `normalizeResourceBundle`, `resourceBundleInfo`, `resourceBundleIdentifier`, `declaredIosTarget` | Rewrites the `Info.plist` of a plugin's resource bundle as Xcode writes it, without Xcode's four keys: the five SDK keys from the user's SDK, `MinimumOSVersion` from the iOS version the package declares (`swift package dump-package`), `UIDeviceFamily`, and the bundle ID with the package version |

Two things in the assets can differ from a Mac build, and neither is a bug in the code. `NOTICES.Z` (the licence list) changes when the Flutter SDK's `LICENSE` files have Windows line endings, which git adds when `core.autocrlf` is true, or when `core.eol` is `crlf` or `native` on Windows; `checkFlutterSdkLineEndings` (for `wincode doctor`) reports it. With an LF checkout the list is the same, except for one byte: the operating-system field of the gzip header, which each host writes for itself (`0x0a` on Windows, `0x13` on a Mac). winCode leaves it as the host wrote it, because setting it to a Mac's value would claim a Mac made the file. `NativeAssetsManifest.json` is empty until the build hooks run (ADR-0010); `nativeAssetsManifest` writes it from their result.

`gen_snapshot` itself is built by the scripts in `engine/`. It has to come from the Dart revision that the app's Flutter release pins: the kernel carries that revision's hash and the tool refuses a kernel from another (ADR-0004). Flutter 3.47.5 and 3.47.7 pin different Dart revisions even though they share one snapshot version hash.

Not here yet for the runner: finding the plugins and their classes from `.flutter-plugins-dependencies` and each plugin's `pubspec.yaml` (`SwiftPlugin` is filled in by hand), the `FlutterFramework` package that some plugins depend on, and the launch events (`application:willFinishLaunching` and `didFinishLaunching`) that Flutter sends late to the plugins of a storyboard's `FlutterViewController`; a view controller made in code does not get them, and neither `shared_preferences_foundation` nor `flutter_secure_storage_darwin` uses them.

Not here yet: `CFBundleIcons` (they come from the asset compiler), the storyboard check (ADR-0011 rule 3), and the check of the entitlements against the provisioning profile.

The resource bundles that `swiftbuild` writes for a plugin's `Resources` have the right name (`<package>_<target>.bundle`), a binary `Info.plist` and the privacy manifest byte for byte as Xcode's. Their `Info.plist` differs from Xcode's in a few keys (placeholder `DTXcode` 10989 and `DTXcodeBuild` 99T999, which winCode never ships, a copied `DTCompiler`, an empty `DTPlatformBuild`, no `UIDeviceFamily`, the build's deployment target in `MinimumOSVersion`, and a bundle ID without the package version when the package folder has none). `normalizeResourceBundle` rewrites it.

```
dart pub get
dart analyze
dart test
```

The tests use a generic sample app with two flavors in `test/fixtures/flavored_sample/`.

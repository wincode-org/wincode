# wincode_core

Dart library: Flutter-to-SwiftPM project translator, plist handling, IPA packaging.

Status: started. What is here so far is the iOS flavor settings (ADR-0011 rules 2 and 6), `flutter_assets` (rule 5) and the Dart code (ADR-0004), `docs/PLAN.md` steps 1, 3, 4 and 7.

| Part | What it does |
| --- | --- |
| `parsePlist`, `parsePlistBytes`, `writePlist` | Read XML and binary property lists, write XML ones with sorted keys |
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

Two things in the assets can differ from a Mac build, and neither is a bug in the code. `NOTICES.Z` (the licence list) changes when the Flutter SDK's `LICENSE` files have Windows line endings, which git adds when `core.autocrlf` is true, or when `core.eol` is `crlf` or `native` on Windows; `checkFlutterSdkLineEndings` (for `wincode doctor`) reports it. With an LF checkout the list is the same, except for one byte: the operating-system field of the gzip header, which each host writes for itself (`0x0a` on Windows, `0x13` on a Mac). winCode leaves it as the host wrote it, because setting it to a Mac's value would claim a Mac made the file. `NativeAssetsManifest.json` is empty until the build hooks run (ADR-0010).

`gen_snapshot` itself is built by the scripts in `engine/`. It has to come from the Dart revision that the app's Flutter release pins: the kernel carries that revision's hash and the tool refuses a kernel from another (ADR-0004). Flutter 3.47.5 and 3.47.7 pin different Dart revisions even though they share one snapshot version hash.

Not here yet: normalizing the resource bundles' `Info.plist` (see below), `CFBundleIcons` (they come from the asset compiler), the storyboard check (ADR-0011 rule 3), and the check of the entitlements against the provisioning profile.

The resource bundles that `swiftbuild` writes for a plugin's `Resources` have the right name (`<package>_<target>.bundle`), a binary `Info.plist` and the privacy manifest byte for byte as Xcode's. Their `Info.plist` has placeholder Xcode values (`DTXcode` 10989 and `DTXcodeBuild` 99T999, which winCode never ships), an empty `DTPlatformBuild`, no `UIDeviceFamily`, and a bundle ID without the package version.

```
dart pub get
dart analyze
dart test
```

The tests use a generic sample app with two flavors in `test/fixtures/flavored_sample/`.

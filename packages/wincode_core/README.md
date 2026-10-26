# wincode_core

Dart library: Flutter-to-SwiftPM project translator, plist handling, IPA packaging.

Status: started. What is here so far is the iOS flavor settings (ADR-0011 rules 2 and 6) and `flutter_assets` (rule 5), `docs/PLAN.md` steps 1, 3 and 7.

| Part | What it does |
| --- | --- |
| `parsePlist`, `parsePlistBytes`, `writePlist` | Read XML and binary property lists, write XML ones with sorted keys |
| `parseOpenStep` | Reads `project.pbxproj` |
| `readXcconfig` | Reads an `.xcconfig` file with its `#include` chain, and conditions such as `[sdk=iphoneos*]` |
| `resolveBuildSettings` | Layers Xcode's defaults, the project's and the target's settings and xcconfig files, for one configuration such as `Release-<flavor>` |
| `buildInfoPlist` | The app's `Info.plist` template with its `$(NAME)` variables replaced, the keys Xcode derives from the settings, the five SDK keys, and no storyboard keys; never Xcode's four (`DTXcode`, `DTXcodeBuild`, `DTCompiler`, `BuildMachineOSBuild`) |
| `buildEntitlements` | The app's `.entitlements` merged with `application-identifier`, the team identifier, `get-task-allow` false and the app's keychain group |
| `readIosFlavor` | All of the above for `--flavor` and a build mode |
| `buildFlutterAssets` | `flutter_assets` for an iOS release build on a host that is not a Mac: `flutter assemble copy_flutter_bundle` with the flavor, then every shader compiled again for iOS with the engine's `impellerc` and flutter_tools' iOS arguments |

Two things in the assets can differ from a Mac build, and neither is a bug in the code. `NOTICES.Z` (the licence list) changes when the Flutter SDK's `LICENSE` files have Windows line endings, which a git checkout does with `core.autocrlf=true`; use an SDK with LF endings. `NativeAssetsManifest.json` is empty until the build hooks run (ADR-0010).

Not here yet: `CFBundleIcons` (they come from the asset compiler), the storyboard check (ADR-0011 rule 3), and the check of the entitlements against the provisioning profile.

```
dart pub get
dart analyze
dart test
```

The tests use a generic sample app with two flavors in `test/fixtures/flavored_sample/`.

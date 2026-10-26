# wincode_core

Dart library: Flutter-to-SwiftPM project translator, plist handling, IPA packaging.

Status: started. What is here so far is the iOS flavor settings (ADR-0011 rules 2 and 6, `docs/PLAN.md` step 1 and 7).

| Part | What it does |
| --- | --- |
| `parsePlist`, `parsePlistBytes`, `writePlist` | Read XML and binary property lists, write XML ones with sorted keys |
| `parseOpenStep` | Reads `project.pbxproj` |
| `readXcconfig` | Reads an `.xcconfig` file with its `#include` chain, and conditions such as `[sdk=iphoneos*]` |
| `resolveBuildSettings` | Layers Xcode's defaults, the project's and the target's settings and xcconfig files, for one configuration such as `Release-<flavor>` |
| `buildInfoPlist` | The app's `Info.plist` template with its `$(NAME)` variables replaced, the keys Xcode derives from the settings, the five SDK keys, and no storyboard keys; never Xcode's four (`DTXcode`, `DTXcodeBuild`, `DTCompiler`, `BuildMachineOSBuild`) |
| `buildEntitlements` | The app's `.entitlements` merged with `application-identifier`, the team identifier, `get-task-allow` false and the app's keychain group |
| `readIosFlavor` | All of the above for `--flavor` and a build mode |

Not here yet: `CFBundleIcons` (they come from the asset compiler), the storyboard check (ADR-0011 rule 3), and the check of the entitlements against the provisioning profile.

```
dart pub get
dart analyze
dart test
```

The tests use a generic sample app with two flavors in `test/fixtures/flavored_sample/`.

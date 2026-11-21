# Spike F, part 2: a storyboard-free build with all plugins, on a device

Status: written 2026-11-20, result added 2026-11-21. Build 17 was uploaded, processed as valid, and run on an iPhone by the maintainer: **every step that was reported passed** (section "Result"). The rest of the page is the plan as it was written.

## Question

Spike F (`spike-f-launch-events.md`) showed on a simulator that the runner's view controller, made the way a storyboard makes it (variant C), gives plugins the same application launch events as a storyboard does. The simulator could not run the URL scenarios, in any variant. Every grafted build that ran Google sign-in on a device carried Xcode's storyboard, so none of them used the code-made view controller (producer matrix, "Not proven").

Does a build with no storyboard, linking all the plugins of a real app, launch, and complete the two sign-ins that return to the app through a URL, on an iPhone?

## The build

A grafted build of a real app (eleven native plugins, nine of them registered plugin classes), made like the last build that ran on a device, with these changes and no others:

- `Runner`: built by `wincode_core` from `main`; its scene delegate is `sceneDelegateBase`, equal to spike F's variant C.
- `Info.plist`: no `UIMainStoryboardFile`, and no `UISceneStoryboardFile` in the scene configuration. `UILaunchScreen` keeps its colour name.
- `Base.lproj/Main.storyboardc`: removed (three files).
- `App.framework/App`: rebuilt in the fixed folder below.
- The build number.

Checked before any upload:

| Check | Result |
| --- | --- |
| `tools/ipa-diff` against the previous device build | Only the build number, the two storyboard keys and the storyboard files differ. `Runner` and `App` are new files, and `ipa-diff` compares them by load commands, which are equal; there is no entitlement or resource difference. |
| `tools/ipa-diff` against the Xcode-built copy | Only the differences already named in the producer matrix, plus the storyboard keys and files. |
| `tools/ipa-declarations`, signed build | URL types, queried schemes, entitlements and universal-link hosts equal to the Xcode-built copy (4 of 4). |
| Compiler warnings against `docs/expected-warnings.tsv` | 23 in the log, 23 in the list, none new, none missing. |
| `wincode sign`, `wincode preflight`, `wincode upload --dry-run` | All passed. The dry run sent nothing. |

## The build folder is fixed and neutral

Dart's ahead-of-time snapshot embeds the file URI of the generated entry file (`.dart_tool/flutter_build/dart_plugin_registrant.dart`), and the Swift link keeps debug-map paths (object files and package sources) because the symbol table is not stripped. A build in a person's own folders therefore puts a user name and a project folder name into the binaries that go to TestFlight. The Xcode-built copy has the same kind of strings (its CI runner's paths).

The rule: build in the same neutral folders every time, so no path names a person, a client or a project, and the same inputs give the same paths.

| Where | Folder | Holds |
| --- | --- | --- |
| Windows | `C:\build\app` | A copy of the app's source without `.git`, `.dart_tool` and `build`. `flutter pub get --offline` and the kernel compile run here. |
| Windows | `C:\build\out`, `C:\build\snap`, `C:\build\runner-layout`, `C:\build\runner-work` | The kernel, the finished `App` and `Runner`, the `gen_snapshot` work folder, the generated runner package, the logs. |
| WSL | `/var/tmp/build/pub` | Copies of the plugin packages (public sources). |
| WSL | `/var/tmp/build/layout`, `/var/tmp/build/scratch`, `/var/tmp/build/fw`, `/var/tmp/build/stubs` | The runner package, SwiftPM's scratch folder (its checkouts and objects), the Flutter framework folder, the `actool` stub. |

Measured on the last two builds: the `Runner` of the earlier build held 2,696 path-like strings (debug-map entries), all under a home folder with a user name or under the project's own folder. The `Runner` built in the fixed folders holds the same number of them, all under `/var/tmp/build`, and none with a user name, a project or client folder name, `/home/` or `/mnt/`. The one folder path in `App` is now `file:///C:/build/app/.dart_tool/flutter_build/dart_plugin_registrant.dart`. Its constants section is 16 bytes shorter, which fits the shorter path.

Nothing enforces the folders yet. The check is a search of the finished `Runner` and `App` (and of the IPA) for the user name, the names of the project and client folders, `/home/` and `/mnt/`; each should find nothing. (`/home/` also appears twice in `App` as the app's own route names.)

## Device test

The tester has an iPhone with the previous build installed from TestFlight, or none. Use the test app record only, and the internal group. Do not enter payment details at any step.

| # | What you do | Pass | If it fails, record |
| --- | --- | --- | --- |
| 0 | Update the app in TestFlight to the new build and open it. Check the version and build number in TestFlight. | The new build number is shown. | Version, build number, iOS version. |
| 1 | Launch. Close the app from the app switcher, then open it again. Do this twice. | The launch colour, then the home screen, within a few seconds, both times. | What the screen shows (black, white, frozen), how long you waited, whether it quit. |
| 2 | Sign in with Google. Pick an account. | The Google account sheet opens, and after you pick, you are back in the app and the sign-in is handled (signed in, or the app's own server message). | The text on screen at the end; whether the Google page stayed open; whether the sheet never opened ("could not be completed" at once). |
| 3 | Sign out, then sign in with Apple. Confirm with Face ID or the passcode. | The Apple sheet opens with the account, and after you confirm you are back in the app and it handles the result. | The text on screen; whether the sheet never opened; whether the app returned with an error. |
| 4 | Go through checkout until the payment sheet appears. Look at it, then close it without paying. | The sheet opens and shows its payment form. | Whether it opened; the text if an error showed. |

A note on step 4: reaching the sheet makes the app ask its server for a payment intent. A build of the production flavor does that against the live server, which is what the earlier device builds did too. Nothing is charged unless the payment is completed, and the step says not to complete it.

## What the result means

- **All five pass:** the storyboard leaves the Apple-made list. The producer matrix row for `Main.storyboardc` changes from "copied" to "not needed", and "Not proven" loses its first line: URL redirects reach plugins when the runner makes its view controller in code, for the two sign-ins of this app, on this device.
- **Any step fails:** report which step, and the record column above. Do not change anything. The report names which launch events or URL callbacks were missed, with that evidence, and the work stops there: the design of a fix is a separate task. The next measurement would be a build with a plugin that records every launch event and URL callback it receives, as spike F's did on the simulator.

## Result

Build 17 was uploaded to the test app record (internal group only) and processed as valid on 2026-11-21, about 4 minutes after the upload started, with no error and one notice: code 90725, Apple's note that from April 2027 uploads must be built with the iOS 27 SDK (this build used 26.5).

The maintainer ran it from TestFlight on one iPhone. The report names steps 1 to 4, and all of them passed: two cold launches, Google sign-in, Apple sign-in, and the payment sheet opening. The report does not mention step 0, the build number shown in TestFlight; the build that ran is the upload of build 17. Nothing was paid. The iOS version was not recorded.

By the rule above, the storyboard leaves the Apple-made list, and the producer matrix records it. The "Not tested" list below still stands.

## Not tested

- Deep links and universal links: the reference app wires neither (no URL scheme of its own, no associated domains), so there is no behaviour to compare.
- A 3-D Secure or redirect payment return: the reference's payment sheet has no return URL, and testing a payment needs a test-mode key, which the production flavor does not carry.
- Apple Pay: not configured in the reference.
- One device and one iOS version. Earlier iOS versions (the minimum is 15) are not covered.

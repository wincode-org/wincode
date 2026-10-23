# Spike C: App Store acceptance of a Windows-built IPA

Status: uploaded 2026-10-23. **Apple accepted C1 and processed its build as `VALID`,** with no errors, warnings or infos.
- **Done:** steps 1 to 8. The maintainer made the certificate, the profile and the app record by hand, and said yes to one upload.
- **Next:** TestFlight's status and the team's email (step 9), then internal testing and the install (steps 10 and 11).
- **Build 1 is used:** the next upload needs build 2 or higher.

The test developer team's account holder has agreed to spike C in writing. This is C1: the app icon's `Assets.car` and the launch storyboard come from Xcode, so the run tests the rest of the bundle. C2 repeats it with winCode's own `Assets.car`.

## Question

Does App Store Connect accept an IPA built and signed on Windows (WSL2), and does that build install from TestFlight?

**Pass** (`docs/PLAN.md`): the build reaches "Ready to Test" in TestFlight with no ITMS warning, then installs and runs on the iPhone.

## Decisions (maintainer, 2026-10-23)

1. **Certificate and profile by hand:** the maintainer makes the Apple Distribution certificate (from `dist.csr`) and the App Store profile in the developer portal. No Admin API key.
2. **Upload route:** the Build Uploads API first. Transporter only if that fails, and it isn't installed without asking.
3. **zsign:** built from the version xtool uses, checked by the pinned commit and a checksum, with Ubuntu's `make` and `libssl-dev`.
4. **App identity:** the bundle ID, version and build number come from the maintainer's local config, never from the repo.

## Rules

- **Code makes one write to Apple, the upload, and a STOP comes before it.**
  - First `asc_upload.py --dry-run` shows every request.
  - Nothing is sent until the maintainer says yes, and one yes covers one upload.
  - Every other write is the maintainer's, by hand in the developer portal or App Store Connect.
  - The preflight stays read-only.
- **Never revoke or replace anything that exists on the team:** certificates, profiles, App IDs, app records, builds, testers.
- **If a limit blocks us, stop and tell the maintainer,** for example when the team already has the maximum number of distribution certificates. Never free a slot by revoking.
- **No devices:** App Store profiles have none.
- **Names stay out of the repo:** the team, its ID, the bundle ID and app name, the Key ID and the Issuer ID never go into a repo file, a log or a PR.

## Local files and secrets

Named by environment variables, outside the repo and OneDrive; the scripts refuse folders inside either.

| Variable | Names |
| --- | --- |
| `WINCODE_DIST_KEY` | `dist.key` (step 1). It stays on the WSL disk: `sign.py` refuses a path under `/mnt/`. `dist.csr` sits beside it |
| `WINCODE_SPIKE_C_DIR` | A folder with the certificate (one `.cer`) and the App Store profile (one `.mobileprovision`) as downloaded, `dist.csr` for the portal, `config.json`, and a note of what each write created (the undo list). It may be on a Windows drive, so the maintainer can edit it in Notepad |
| `WINCODE_ASC_KEY_DIR` | A folder with `AuthKey_<Key ID>.p8` as downloaded (not renamed: the Key ID is read from the name) and `issuer-id`, a file with no extension holding the Issuer ID on one line; used by the preflight and the upload |

`config.json`: `{"bundle_id": "<bundle id>", "version": "1.0", "build": "1"}`. Each later upload takes a higher build number; build 1 was used on 2026-10-23. The scripts accept the byte order mark Notepad may write.

- **The distribution key** is RSA 2048, PKCS#8, on the WSL disk (ext4; folder 700, file 600).
  - Its backup is on a second physical disk, encrypted with a passphrase (PBKDF2-HMAC-SHA256, 600,000 iterations, AES-256-CBC).
  - A later `wsl --export` copies the key into the tar in clear, so keep such tars like the key.
- **The API scripts** never print the key, the Key ID, the Issuer ID or the token.
  - A dry run shows `Authorization: Bearer <token signed locally, not shown>`.
  - An HTTP error shows Apple's error code and detail only.
  - The token never follows a redirect, and never goes to the upload URLs.
- **The product** keeps these secrets in Windows Credential Manager (ADR-0009); the spike uses files.

## Steps

### 0. Before the first request

- **Agreements:** the account holder has accepted the latest agreements in App Store Connect. Pending agreements make the API answer 403 and block uploads.
- **API key:** an App Store Connect API key on the team whose role can upload builds. Admin isn't needed, since the certificate is made by hand.
- **Tester:** the maintainer's Apple ID is a user of the team in App Store Connect, so it can be an internal tester (step 10).
- **SDK:** the Darwin SDK comes from the final Xcode 26.6 (iPhoneOS 26.5 SDK). That meets the rule that uploads use Xcode 26 and an iOS 26 SDK.
- **Bundle ID:** a dedicated one. Once a build is uploaded, Apple never lets that bundle ID be used again, even if the app is removed.
- **Reference (plan step 1):**
  - The macOS run 39513689791, kept outside the repo since spike D.
  - Its Xcode-built counter app is unsigned, so it is a reference for the bundle, not for the signature.
  - No new macOS run without asking.

### 1. Distribution key and backup (local): done 2026-10-21

`bash spikes/c-store-acceptance/dist-key.sh <key dir> <backup dir>`, run by the maintainer in a WSL terminal.
- **It made** `dist.key` and `dist.csr`, wrote `dist.key.enc.pem` to the backup folder and passed the restore check. It never overwrites.
- **Checked afterwards:**
  - The key is RSA 2048, folder 700 and files 600.
  - The CSR verifies and carries the key's public key.
  - The backup is 1,878 bytes of encrypted PKCS#8 on a second physical disk.

### 2. Preflight (GET only)

```bash
python3 spikes/c-store-acceptance/asc_preflight.py --self-test
python3 spikes/c-store-acceptance/asc_preflight.py --dry-run
python3 spikes/c-store-acceptance/asc_preflight.py
```

It sends GET requests only, and stops if a request is anything else. It prints PASS or FAIL for three checks, and exits non-zero if one fails:
- the API key works;
- the app record is found by the config's bundle ID;
- the app has no builds and no build uploads yet.

Then it prints a table of the team's certificates (type, expiry, count per type) and the App ID and profiles that match the bundle ID, without names or identifiers. What decides the next steps:
- **Distribution certificates** (`DISTRIBUTION`, `IOS_DISTRIBUTION`): Apple caps them per team; third-party docs say three. At the cap: STOP.
- **App ID and app record:** whether they already exist.
- **Profiles:** existing ones are left alone.

If the key's role can't read certificates, the preflight shows Apple's 403 after the three checks; the developer portal shows the same list.

**Run 2026-10-23** (after steps 3 and 4): the dry run printed six GETs; the real run passed all three checks, and listed our App ID with one active App Store profile. It passed again right before the upload.

### 3. Certificate and profile, by hand in the developer portal (maintainer)

1. **App ID:** register an explicit App ID for the bundle ID if the preflight found none. It needs no capabilities.
2. **Certificate:** a new Apple Distribution certificate from `dist.csr`. At the cap: stop.
3. **Profile:** an App Store profile for that App ID and that certificate.
4. **Download** the `.cer` and the `.mobileprovision` into `WINCODE_SPIKE_C_DIR`, and note the certificate and profile in the undo list.

### 4. App record, on the App Store Connect website (maintainer or account holder)

- **Why the website:** the API can't create apps; `/v1/apps` takes only GET and PATCH.
- **Values:** Apps, then New App: iOS, a name, the primary language, the bundle ID and a SKU.

### 5. zsign (local): done 2026-10-23

```bash
bash spikes/c-store-acceptance/build-zsign.sh <dir>
```

- **Source:** the commit xtool pins, `xtool-org/zsign` 1.9.0 (`f6158be9`, MIT). The script refuses to build if `third_party/xtool/Package.resolved` no longer pins it.
- **Checksum:** it downloads GitHub's archive of that commit (23,623,184 bytes) and checks its SHA-256, `423ebe2f4dd3380367461c03e6de3b9e9f31adcbe9a2f0237493c8f0bf9b7c5d`. On 2026-10-23 the archive's 243 files were identical to xtool's own checkout of the commit.
- **Build:** it uses the Swift toolchain's clang, since g++ isn't installed.
- **Installed for it:** Ubuntu's `make` 4.3-4.1build2 and `libssl-dev` 3.0.13-0ubuntu3.16, from archive.ubuntu.com.
- **zsign's behaviour:** it signs only main executables with entitlements (`archo.cpp`), so frameworks get none (spike E, finding 6). It embeds the Apple intermediate that matches the certificate's issuer.

### 6. The C1 bundle, unsigned (local)

```bash
python3 spikes/c-store-acceptance/c1_bundle.py <spike D's d-assets.app> <reference folder> <out dir>
```

It starts from spike D's counter bundle (`spikes/d-store-parity/build.sh`, PR #17), with the five SDK keys, the release runner, the merged Info.plist and iOS shaders. Then it adds:

- **From `config.json`:** `CFBundleIdentifier`, `CFBundleShortVersionString` and `CFBundleVersion`.
- **From Xcode:**
  - The icon sample's compiled `Assets.car`, `AppIcon60x60@2x.png` and `AppIcon76x76@2x~ipad.png` (actool on the runner).
  - Its partial Info.plist's `CFBundleIcons` and `CFBundleIcons~ipad`.
  - The counter app's compiled `Base.lproj/LaunchScreen.storyboardc`, with `UILaunchStoryboardName`; `UILaunchScreen` is dropped.
  - The runner is a SwiftUI app, so it needs no `Main.storyboardc` and no scene configuration.
- **From the zero-rejection checks** (`docs/PLAN.md`):
  - `ITSAppUsesNonExemptEncryption` false: the app uses no encryption.
  - `PrivacyInfo.xcprivacy` with Apple's four keys, all empty: the runner calls no required-reason API, collects nothing and doesn't track. `Flutter.framework` ships its own manifest.
  - The script checks that `MinimumOSVersion` is 13 or later; it is 15.0.
- **Metadata (plan step 3):**
  - `DTXcode`, `DTXcodeBuild`, `DTCompiler` and `BuildMachineOSBuild` can't be filled truthfully, because no Xcode or Mac built the app, so they stay out.
  - If Apple refuses the build for their absence, that is the plan's "toolchain rejection not fixable with honest metadata".

It writes the `.app`, `c1-unsigned.ipa` and `ipa-diff-c1.txt` against Xcode's counter app.

**ipa-diff, 2026-10-23** (lines per category: Info.plist, layout, load commands, entitlements, resources):

| Bundle | Info.plist | Layout | Load | Entitlements | Resources |
| --- | --- | --- | --- | --- | --- |
| Spike D's counter bundle | 11 | 7 | 9 | 0 | 12 |
| C1, placeholder bundle ID, version 1.0.0 | 9 | 4 | 9 | 0 | 11 |
| C1, the config's bundle ID, version 1.0, build 1 | 10 | 4 | 9 | 0 | 11 |

What still differs:
- **Info.plist:**
  - The four Xcode and Mac keys (above).
  - `CFBundleExecutable`, the runner's name.
  - `CFBundleIdentifier` and `CFBundleShortVersionString` (1.0 against Xcode's 1.0.0), from the config.
  - `ITSAppUsesNonExemptEncryption`, which only C1 has.
  - Xcode's `UIMainStoryboardFile` and scene configuration, which the SwiftUI runner doesn't use.
- **Layout:**
  - `PrivacyInfo.xcprivacy`, which only C1 has.
  - Xcode's `PkgInfo` and `AppFrameworkInfo.plist`.
  - `App.framework/_CodeSignature`; signing adds it.
- **Load commands:**
  - lld instead of Apple's ld.
  - The runner links SwiftUI and Swift concurrency, where Xcode's Flutter runner links only Foundation and UIKit (spike D).
- **Resources:**
  - The icon files: the icon sample's icon, not the counter app's.
  - Xcode's `Main.storyboardc`.
  - `NOTICES.Z` and `MaterialIcons-Regular.otf`, from spike E's asset-bundle stopgap.
  - The native-asset manifest's JSON formatting.
- **Launch image:** the launch storyboard shows the `LaunchImage` asset, which the icon sample's `Assets.car` doesn't have, so the launch screen is blank.

### 7. Sign (local)

```bash
python3 spikes/c-store-acceptance/sign.py --dry-run <C1 .app> <out .ipa>
python3 spikes/c-store-acceptance/sign.py <C1 .app> <out .ipa>
```

- **Checks before signing:**
  - The certificate is a distribution certificate for `dist.key` and hasn't expired.
  - The profile is an App Store profile (no devices, no `get-task-allow`) for the config's bundle ID and includes the certificate.
  - The bundle carries the config's bundle ID.
- **Entitlements:** a minimal set, built at run time from the profile's team ID and the config's bundle ID; nothing about the team or app is in the repo.
  - `application-identifier`: team ID + bundle ID.
  - `com.apple.developer.team-identifier`: team ID.
  - `get-task-allow`: false.
  - `keychain-access-groups`: [team ID + bundle ID]. The team's wildcard group is not used.
  - `beta-reports-active` is not added.
  - Every key and value must be allowed by the profile (equal, or matched by its trailing `*`), or the script stops. `sign.py --self-test` checks that rule.
  - **Not verified against Xcode:** no Xcode-signed reference exists, so this set is a guess at what Xcode signs.
- **Dry run:** it lists what is still missing, the entitlements, and the zsign command. IDs are masked.
- **Signing:** zsign signs a copy in a temporary folder and writes the IPA to a separate one, then the script reads every signature back.
  - zsign is stopped and the IPA deleted if its files pass 1 GB (an earlier test zipped its own output in a loop).
  - Every Mach-O must be signed.
  - The main executable must carry exactly the minimal set, and every framework none.
  - `embedded.mobileprovision` must be there, and the IPA must hold only `Payload/`.

**Run 2026-10-23:** inputs OK (the profile includes our certificate and allows every key). Signed in one pass: the executable carries the four entitlements above, `App.framework` and `Flutter.framework` carry none, and the 6,703,711-byte IPA holds only `Payload/`.

### 8. Upload through the Build Uploads API (STOP)

```bash
python3 spikes/c-store-acceptance/asc_upload.py --dry-run <signed .ipa>
python3 spikes/c-store-acceptance/asc_upload.py <signed .ipa>     # only after the maintainer's yes
```

1. **Find the app:** `GET /v1/apps?filter[bundleId]=…` gives the app record's ID.
2. **Create the upload:** `POST /v1/buildUploads` with the app, `cfBundleShortVersionString`, `cfBundleVersion` and platform `IOS`.
3. **Reserve the file:** `POST /v1/buildUploadFiles` with `assetType` `ASSET`, `fileName`, `fileSize` and `uti` `com.apple.ipa`.
4. **Send the parts:** each part goes as the answer's `uploadOperations` say (method, URL, byte range, headers), without the token.
5. **Commit:** `PATCH /v1/buildUploadFiles/{id}` with `uploaded` true and the IPA's MD5 in `sourceFileChecksums`.
6. **Wait:** `GET /v1/buildUploads/{id}` with `include=build,assetFile`, every 30 s for up to 15 minutes after the commit, until the upload or its file fails or the build leaves `PROCESSING`. It prints each change of state (upload, file, build) with its time, and each of Apple's `errors`, `warnings` and `infos` once, as sent.

- **Before anything is sent,** the IPA must carry the config's bundle ID, version and build number, and a profile.
- **The request bodies** follow App Store Connect API 4.5.1.
- **Two guesses, both right for C1:**
  - The MD5 in hex was accepted: the file reached `COMPLETE` with no errors.
  - No `ASSET_DESCRIPTION` file was needed: the upload reached `COMPLETE` with the IPA alone. (The 4.5.1 spec gives a build upload `assetDescriptionFile` and `assetSpiFile` relationships.)
- **Any refusal stops it, with no retry:**
  - An HTTP error on any API request prints Apple's errors as sent, each error's own ID masked, and ends the script.
  - A part's error prints its answer with URLs hidden, since a part's URL is a signed, temporary link.
  - A failed upload, file or build ends the script too, after Apple's messages.
- **Output:** each step with its UTC time. The bundle ID, the team ID and Apple's IDs for the app record, the upload and the file are masked.
- **Dry run 2026-10-23:** it printed the six requests and the upload-operations placeholder, with the bundle ID masked, Apple's IDs as placeholders and no token.
- **If this route fails,** Transporter for Windows is the fallback. Forum reports say it also wants an `AppStoreInfo.plist`, which Apple's Mac tools write. It isn't installed without asking. C1 didn't need it.

**Run 2026-10-23,** the one attempt the maintainer said yes to.
- **Before it:** the preflight passed all three checks again. The signed IPA was unchanged: same size, same MD5 as at the dry run, the same signatures read back, and the config's bundle ID, version 1.0 and build 1.
- **Each answer, by time (UTC; the PC's clock is UTC+1):**

| Time | Step | Apple's answer |
| --- | --- | --- |
| 22:25:55 | Find the app (GET) | The app record, found by bundle ID |
| 22:25:56 | Create the upload (POST) | Accepted: version 1.0, build 1 |
| 22:26:18 | Reserve the file (POST) | Accepted: two parts to send |
| 22:27:04 | Part 1 | Accepted: 5,242,880 bytes |
| 22:27:16 | Part 2 | Accepted: 1,460,831 bytes |
| 22:27:21 | Commit (PATCH) | Accepted; file `COMPLETE`, no errors, no warnings |
| 22:27:23 | Processing (GET) | Upload `PROCESSING`, no build yet |
| 22:29:31 | Processing (GET) | Upload `COMPLETE`, build `VALID` |

- **Apple's messages:** none. The upload, the file and the build gave no errors, warnings or infos at any stage.
- **Time taken:** under four minutes from the first request to the processed build.

### 9. Apple's verdict (GET only)

- **The upload:** its state, errors, warnings and infos (step 8).
- **TestFlight:** the build's processing state.
- **Email:** Apple's email to the team.

Every code and message goes into this doc word for word, without names. Any ITMS warning means no pass.

**C1, 2026-10-23:** the upload is `COMPLETE` and the build `VALID`, and the API gave no errors, warnings or infos. Not checked yet: TestFlight's status ("Ready to Test") and Apple's email to the team.

### 10. Internal testing, on the website (maintainer or account holder)

- **No review:** internal testers need no Beta App Review.
- **Tester first:** if the maintainer isn't yet a user of the team, the account holder adds them (Users and Access).
- **Then:** an internal group on the test app with the maintainer in it, and the build added to it.

### 11. Install from TestFlight on the iPhone

Install the build from the TestFlight app and launch it. The counter must start and count.

## What each write changes, and how to undo it

| Write | Who | Changes on the team | Undo |
| --- | --- | --- | --- |
| App ID | Maintainer, portal | One explicit App ID, no capabilities | Delete it while no app record uses it; after that it stays. Once a build is uploaded, the identifier can never be reused |
| Distribution certificate | Maintainer, portal | One more Apple Distribution certificate, valid for a year. It takes a slot under Apple's cap and is listed for the team's Admins; only this PC holds its private key | Revoke this certificate only. Our profile becomes invalid, and TestFlight may stop installing builds signed with it. The team's apps don't use it |
| App Store profile | Maintainer, portal | One profile for the test App ID, no devices | Delete it |
| App record | Maintainer or account holder, website | A private app; it reserves the name and takes the bundle ID and the SKU | Remove the app (App Store Connect Help, "Remove an app"). The SKU can't be reused on the team, and the bundle ID can't be reused once a build was uploaded |
| Upload | `asc_upload.py`, after a STOP | A build under the test app; Apple processes it and may email the team. The build number is used up | None: builds can't be deleted. Expire it in TestFlight |
| Internal testing | Maintainer or account holder, website | An internal group and its tester, plus a team user if one was added | Delete the group; the account holder removes the user |

## Results

| Result | Meaning | Next |
| --- | --- | --- |
| Ready to Test, no warnings | The pure-Windows lane works technically | Build that lane in the Ship phase; run C2 later |
| Fixable error | A packaging gap | Fix it, add a doctor check, upload again |
| Toolchain rejection, not fixable with honest metadata | Pure-Windows store builds are blocked | The cloud Mac lane becomes the store lane for good |

## Tested offline

- **`asc_preflight.py`:**
  - `--self-test` checks the token against Apple's documented format, and `openssl dgst -verify` accepts its signature.
  - `--dry-run` prints the GETs, masks the bundle ID and hides the token.
  - Key folders inside the repo or OneDrive, a renamed or second `.p8`, a bad Issuer ID and an RSA key are refused. No message names the key file or the IDs.
- **`dist-key.sh`,** with a throwaway key:
  - The restore check passes, and a wrong passphrase fails it.
  - Reruns change no file.
- **`c1_bundle.py`:** built the C1 bundle from spike D's counter bundle, with a placeholder bundle ID (table above).
- **`sign.py`:**
  - The dry run lists the missing certificate and profile.
  - A profile for another bundle ID is refused.
  - A full signing run used a throwaway CA-issued identity and profile, passed to zsign as a `.p12` through a test wrapper; real Apple certificates need no wrapper. The main executable carried the profile's entitlements, both frameworks carried none, and the IPA held only `Payload/`.
  - `--self-test`: the minimal set is built from a profile, and refused when the profile lacks a key, has `get-task-allow` true, or allows another keychain group or bundle ID.
  - With the limit lowered to 1 MB, zsign was stopped and no file was left in the output folder.
- **`asc_upload.py --dry-run`:**
  - It prints every request, with placeholders for Apple's IDs, and never the token, the Key ID or the Issuer ID.
  - A real run without a key, a build number that differs from the config, and an unsigned IPA are all refused.
- **`asc_upload.py`, real path against a fake Apple,** with networking blocked:
  - **Cases:** a normal run, a refused create, a refused part, a refused commit, a failed processing, and the 15-minute stop.
  - **Refusals:** each one stopped the script at once, with Apple's message whole, and nothing more was sent.
  - **Parts:** they rebuilt the IPA byte for byte, and the token never went with one.
  - **Output:** no ID and no part URL was printed.

# Spike C: App Store acceptance of a Windows-built IPA

Status: prepared 2026-10-21; step 1 is done. **Nothing has been sent to Apple yet.** The test developer team's account holder has agreed to spike C in writing. This is C1: the app icon's `Assets.car` comes from Xcode, so the run tests the rest of the bundle; C2 repeats it with winCode's own `Assets.car`.

## Question

Does App Store Connect accept an IPA built and signed on Windows (WSL2), and does that build install from TestFlight?

**Pass** (`docs/PLAN.md`): the build reaches "Ready to Test" in TestFlight with no ITMS warning, then installs and runs on the iPhone.

## Rules

- **A STOP before every write to Apple.** First the request is shown: method, URL and body with the real values, never the `Authorization` header. Nothing is sent until the maintainer says yes. One yes covers one write; an upload's create, reserve, send and commit requests are one write and are shown together.
- **Never revoke or replace anything that exists on the team:** certificates, profiles, App IDs, app records, builds, testers. Our own writes are undone only after their own yes.
- **If a limit blocks us, stop and tell the maintainer,** for example when the team already has the maximum number of distribution certificates. Never free a slot by revoking.
- **No devices:** App Store profiles have none, so spike C registers no device.
- **Names stay out of the repo:** the team, its ID, the bundle ID and app name, the Key ID and the Issuer ID never go into a repo file, a log or a PR.
- **An undo list:** what each write created (kind, resource ID, date) is noted in a file next to the distribution key, outside the repo.

## Secrets

| Secret | Where | Rules |
| --- | --- | --- |
| App Store Connect API key | The folder that `WINCODE_ASC_KEY_DIR` names, outside the repo and OneDrive: `AuthKey_<Key ID>.p8` as downloaded, and `issuer-id` with the Issuer ID on one line | `asc_preflight.py` refuses a folder in the repo or OneDrive and never prints the key, the Key ID, the Issuer ID or the token |
| Distribution private key | RSA 2048, PKCS#8, on the WSL disk (ext4; folder 700, file 600), outside the repo and OneDrive | Made on this PC and never sent anywhere; Apple only sees the CSR |
| Its backup | A second physical disk, outside OneDrive: PKCS#8 encrypted with a passphrase (PBKDF2-HMAC-SHA256, 600,000 iterations, AES-256-CBC) | The passphrase is typed at openssl's prompt and never stored; it belongs in a password manager |

- **What the preflight shows:** `--dry-run` prints `Authorization: Bearer <token signed locally, not shown>`; an HTTP error prints Apple's error code and detail only.
- **Flags:** tools that take the Key ID and Issuer ID as flags (Transporter's `-apiKey`, `-apiIssuer`) run without echoing or logging their command line.
- **WSL exports:** a later `wsl --export` copies the distribution key into the tar in clear; keep such tars like the key.
- **The product** keeps these secrets in Windows Credential Manager (ADR-0009); the spike uses files.

## Steps

### 0. Before the first request

- **The key's role:**
  - The plan has the account holder or an Admin create a new distribution certificate.
  - With an Admin key, W2 is that request, sent only after the maintainer's yes.
  - With a lesser key, the account holder creates the certificate from our CSR.
- **Agreements:** the account holder has accepted the latest agreements in App Store Connect. Pending agreements make the API answer 403 and block uploads.
- **Tester:** the maintainer's Apple ID is a user of the team in App Store Connect, so it can be an internal tester (step 10).
- **SDK:** the Darwin SDK comes from the final Xcode 26.6 (iPhoneOS 26.5 SDK). That meets the rule that uploads use Xcode 26 and an iOS 26 SDK.
- **App:**
  - Spike E's counter app, built by spike D's `build.sh` (PR #17).
  - The maintainer and the account holder choose a dedicated bundle ID and app name. Once a build is uploaded, Apple never lets that bundle ID be used again, even if the app is removed.
- **Reference (plan step 1):**
  - The Xcode-built counter app from run 39513689791, kept outside the repo since spike D.
  - It is unsigned, so it is a reference for the bundle, not for the signature.
  - No new macOS run without asking.

### 1. Distribution key and backup (local)

In a WSL terminal:

```bash
bash spikes/c-store-acceptance/dist-key.sh <key dir> <backup dir>
```

- **It makes** `dist.key` and `dist.csr`, writes `dist.key.enc.pem` to the backup folder, then asks for the passphrase again and checks that the backup decrypts to the same key.
- **It never overwrites:** running it again repeats only the restore check.
- **The certificate request (W2) waits** until this prints `restore check OK`.

**Done 2026-10-21.**
- **The maintainer ran it,** and the restore check passed.
- **The key:** RSA 2048, on the WSL disk, folder 700 and files 600. The CSR verifies and carries the key's public key.
- **The backup:** 1,878 bytes on a second physical disk, encrypted PKCS#8 (PBES2, PBKDF2 with hmacWithSHA256 and 600,000 iterations, AES-256-CBC).

### 2. Preflight (GET only)

```bash
export WINCODE_ASC_KEY_DIR=<key folder>
python3 spikes/c-store-acceptance/asc_preflight.py --self-test
python3 spikes/c-store-acceptance/asc_preflight.py --dry-run <bundle id>
python3 spikes/c-store-acceptance/asc_preflight.py <bundle id>
```

It prints the team's certificates (type, expiry, count per type), then the App IDs, apps and profiles that match the bundle ID. What decides the next steps:

- **Distribution certificates** (`DISTRIBUTION`, `IOS_DISTRIBUTION`): Apple caps them per team; third-party docs say three. At the cap: STOP.
- **App ID:** if it exists, W1 is skipped.
- **App:** if it exists, W4 is skipped, once the maintainer confirms it is the test app.
- **Profiles:** existing ones are left alone; W3 makes our own.

### 3. W1: App ID, only if the preflight finds none (STOP)

- **Request:** `POST /v1/bundleIds` with `{"data": {"type": "bundleIds", "attributes": {"identifier": "<bundle id>", "name": "<name>", "platform": "IOS"}}}`, no capabilities.
- **If another team owns the identifier:** STOP and choose another.

### 4. W2: Apple Distribution certificate (STOP)

- **Request:** `POST /v1/certificates` with `{"data": {"type": "certificates", "attributes": {"certificateType": "DISTRIBUTION", "csrContent": "<dist.csr>"}}}`.
- **Answer:** its `certificateContent` is saved as `dist.cer` next to the key.
- **At the cap (HTTP 409):** STOP.

### 5. W3: App Store profile (STOP)

- **Request:** `POST /v1/profiles` with `{"data": {"type": "profiles", "attributes": {"name": "<name>", "profileType": "IOS_APP_STORE"}, "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": "<W1>"}}, "certificates": {"data": [{"type": "certificates", "id": "<W2>"}]}}}}`.
- **Answer:** its `profileContent` becomes `embedded.mobileprovision`, kept outside the repo.

### 6. W4: App record on the website (STOP)

- **Why the website:** the API can't create apps; `/v1/apps` takes only GET and PATCH.
- **Who:** the account holder or an Admin creates it in App Store Connect (Apps, then New App), after the values are shown.
- **Values:** iOS, the name, the primary language, the bundle ID from W1, a SKU.
- **If the name is taken:** choose another.

### 7. Build, metadata, icon and signing (local)

- **Build:** spike D's `build.sh` gives the five SDK keys, the release runner, the merged Info.plist and iOS shaders.
- **Info.plist:**
  - `CFBundleIdentifier` is the test bundle ID.
  - `CFBundleShortVersionString` is 1.0.0 and `CFBundleVersion` is 1; each later upload takes a higher build number.
  - `ITSAppUsesNonExemptEncryption` is false: the counter app uses no encryption, and without the key every build waits for an export answer.
- **Metadata (plan step 3):**
  - **Filled from the SDK's own files** (spike D): `DTSDKName`, `DTSDKBuild`, `DTPlatformName`, `DTPlatformVersion`, `DTPlatformBuild`.
  - **Can't be filled truthfully,** because no Xcode or Mac built the app: `DTXcode`, `DTXcodeBuild`, `DTCompiler`, `BuildMachineOSBuild`. They stay out.
  - **If Apple refuses the build for their absence,** that is the plan's "toolchain rejection not fixable with honest metadata".
- **Icon (C1, plan step 4):** taken from the reference app, which actool built on the macOS runner:
  - `Assets.car`, `AppIcon60x60@2x.png` and `AppIcon76x76@2x~ipad.png`.
  - The `CFBundleIcons` and `CFBundleIcons~ipad` keys (`CFBundleIconName` AppIcon).
- **zsign (ADR-0009), with an install STOP:**
  - Built in WSL from the zsign that xtool pins: `xtool-org/zsign` 1.9.0, `f6158be9`, MIT.
  - It uses the Swift toolchain's clang instead of g++, which isn't installed (48 MB).
  - It needs Ubuntu's `make` and `libssl-dev` (2 packages, 2.6 MB, from archive.ubuntu.com) and the zsign source from GitHub.
- **Signing,** inside out:
  - Frameworks get no entitlements (spike E, finding 6).
  - The app gets the profile's production entitlements, with no `get-task-allow`, and `embedded.mobileprovision`.
  - Zip `Payload/` into the IPA.
- **Checks before the upload:**
  - `tools/ipa-diff` against the reference: expect spike D's accepted differences, minus the icon.
  - The entitlements of every binary.
  - The zero-rejection checks in `docs/PLAN.md`.

### 8. W5: Upload (STOP)

**Route 1: Transporter for Windows.** It isn't installed yet, so an install STOP comes first.
- **Command:** `iTMSTransporter -m upload -assetFile <ipa> -apiKey <Key ID> -apiIssuer <Issuer ID>`. Where it looks for the `.p8` is checked in its own help once it is installed.
- **First run:** it may update itself from Apple, which makes it an Apple call.
- **AppStoreInfo.plist:**
  - Forum reports say Transporter on Windows and Linux also wants `-assetDescription AppStoreInfo.plist`, a file that Apple's Mac tools write.
  - If it insists, use route 2.
  - Writing that file ourselves would need a format spec first (CONTRIBUTING).

**Route 2: Build Uploads API** (App Store Connect API 4.x):
1. `POST /v1/buildUploads` with the app, `cfBundleShortVersionString`, `cfBundleVersion` and platform `IOS`.
2. `POST /v1/buildUploadFiles` with `assetType` `ASSET`, `fileName`, `fileSize` and `uti` `com.apple.ipa`.
3. PUT each part to the URLs in `uploadOperations`.
4. `PATCH /v1/buildUploadFiles/{id}` with `uploaded` true and `sourceFileChecksums`.

### 9. Apple's verdict (GET only)

- **The upload:** `GET /v1/buildUploads/{id}` gives the state (`PROCESSING`, `FAILED` or `COMPLETE`) with `errors`, `warnings` and `infos`.
- **TestFlight:** the build's processing state.
- **Email:** Apple's email to the team.
- **Recording:** every code and message goes into this doc word for word, without names. Any ITMS warning means no pass.

### 10. W6: Internal testing (STOP)

- **No review:** internal testers need no Beta App Review.
- **Tester first:** if the maintainer isn't yet a user of the team, the account holder adds them (Users and Access).
- **Then:** an internal group on the test app with the maintainer in it, and the build added to it.

### 11. Install from TestFlight on the iPhone

Install the build from the TestFlight app and launch it. The counter must start and count.

## What each write changes, and how to undo it

| Write | Changes on the team | Undo, only with its own yes |
| --- | --- | --- |
| W1 App ID | One explicit App ID, no capabilities | `DELETE /v1/bundleIds/{id}`, but only until an app record uses it; after that it stays. Once a build is uploaded, the identifier can never be reused |
| W2 Distribution certificate | One more Apple Distribution certificate, valid for a year. It takes a slot under Apple's cap and is listed for the team's Admins; only this PC holds its private key | Revoke this certificate only: `DELETE /v1/certificates/{id}`, with the ID recorded at creation. Our profile becomes invalid, and TestFlight may stop installing builds signed with it. The team's apps don't use it, so they aren't affected |
| W3 App Store profile | One profile for the test App ID, no devices | `DELETE /v1/profiles/{id}` |
| W4 App record | A private app in App Store Connect. It reserves the name and takes the bundle ID and the SKU | Remove the app (App Store Connect Help, "Remove an app"). The SKU can't be reused on the team, and the bundle ID can't be reused once a build was uploaded |
| W5 Upload | A build under the test app. Apple processes it and may email the team; the build number is used up | None: builds can't be deleted. Expire it in TestFlight |
| W6 Internal testing | An internal group on the test app and its tester, plus a team user if the account holder added one | Delete the group; the account holder removes the user |

## Results

| Result | Meaning | Next |
| --- | --- | --- |
| Ready to Test, no warnings | The pure-Windows lane works technically | Build that lane in the Ship phase; run C2 later |
| Fixable error | A packaging gap | Fix it, add a doctor check, upload again (another W5) |
| Toolchain rejection, not fixable with honest metadata | Pure-Windows store builds are blocked | The cloud Mac lane becomes the store lane for good |

## Checked on this PC, 2026-10-21

- **Transporter isn't installed:**
  - No `itms` folder under Program Files, Program Files (x86) or the user's AppData.
  - No uninstall entry and nothing on PATH.
  - Nothing in WSL.
- **WSL has what the scripts need:**
  - Python 3.12 with `cryptography` 41, Ubuntu's package.
  - OpenSSL 3.0.13.
  - `script` from util-linux, used only for the tests.
- **`asc_preflight.py --self-test` passes,** with a throwaway key:
  - The header is `alg` ES256, `kid`, `typ` JWT.
  - The claims are `iss`, `iat`, `exp` (`iat` + 600 s) and `aud` `appstoreconnect-v1`.
  - The signature is 64 raw bytes (R||S), base64url without padding, and `openssl dgst -verify` accepts it.
  - Key folders inside the repo or OneDrive are refused.
- **`--dry-run`** prints the four GETs and hides the token. No message names the key file, the Key ID or the Issuer ID.
- **`dist-key.sh`, with a throwaway key:**
  - It made an RSA 2048 key and a SHA-256 CSR.
  - The backup is PBES2: PBKDF2 with hmacWithSHA256 and 600,000 iterations, AES-256-CBC.
  - The restore check passed, and a wrong passphrase failed it.
  - Reruns changed no file, and a CSR without its key was refused.

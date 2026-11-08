# 0013. wincode CLI: build, sign, upload

- Status: Proposed
- Date: 2026-11-08

## Context

- **The hybrid lane is how real apps ship today** (ADR-0008, ADR-0012). A hosted macOS runner in the app's own GitHub repository builds an unsigned IPA with Xcode. On Windows the IPA is signed with zsign (ADR-0009, ADR-0011), checked against App Store Connect, and uploaded through the Build Uploads API. Builds of real apps with third-party sign-in and a payments SDK have reached TestFlight this way.
- **The Windows half is three spike scripts** in `spikes/c-store-acceptance`, in Python:
  - `sign.py` checks the certificate, the profile and the entitlements against each other, signs with zsign, and reads every signature back;
  - `asc_preflight.py` makes GET-only checks (the key works, the app record exists, the app has no builds yet, which the open PR #11 turns into a build-number comparison) and lists the team's certificates and profiles;
  - `asc_upload.py` drives the Build Uploads API, from creating the upload to Apple's processing result.
- **What the scripts need:** Python 3 with the `cryptography` package, `openssl`, zsign built in WSL2, a `config.json` and three environment variables. The macOS half is a workflow file that each app's repository holds, started and downloaded by hand.
- **`wincode` has one command,** `doctor` (Mach-O checks), with its own argument parsing and exit codes 0, 1 and 64.
- **Windows users must not need Python.** They install Flutter, which brings Dart (ADR-0002); the CLI is one Dart executable.

## Decision

### 1. Commands

`wincode <command> [arguments]`. The lane is `wincode build`, then `wincode sign`, then `wincode upload`, and each step also runs alone.

| Command | What it does | Talks to | Phase |
| --- | --- | --- | --- |
| `init` | Writes a commented `wincode.yaml` for the Flutter project in the current folder, from `ios/Runner.xcodeproj` and its xcconfig files, read by `wincode_core`'s flavor reader (`--flavor` for one flavor). From phase 5 it also writes the reference workflow. It never overwrites a file | nothing | 2 |
| `build` | Starts the app's macOS workflow at the configured branch or tag, waits for it, downloads the unsigned IPA to `<output>/unsigned.ipa` and checks it (section 3) | GitHub, through `gh` | 5 |
| `sign [<ipa>]` | Signs for the App Store with zsign, from `<output>/unsigned.ipa` to `<output>/signed.ipa` by default. Checks the inputs first and every signature after (section 4) | nothing | 3 |
| `preflight [<ipa>]` | Read-only checks before an upload. On the IPA (`<output>/signed.ipa` by default): the bundle ID, the version and build number, a signature with an App Store profile that has not expired. In App Store Connect: the key works, the app record exists, the build number is above every existing build's | App Store Connect, GET only | 2 |
| `upload [<ipa>]` | Runs `preflight` and stops if it fails, then uploads through the Build Uploads API and waits up to 15 minutes for Apple's processing result, printing each of Apple's messages as sent | App Store Connect | 4 |
| `status` | The state of the app's latest build uploads and builds, with Apple's messages, for an upload that `upload` stopped waiting for | App Store Connect, GET only | 4 |
| `doctor` | Exists: checks a Mach-O against the SDK's text stubs or a reference build. Each later phase adds the checks of its own setup (zsign, `gh`, the environment variables) | nothing | done |

`upload` is the only command that writes to Apple. No command creates, revokes or deletes a certificate, profile, App ID or app record (ADR-0009).

**Global options,** accepted before or after the command name:

| Option | Meaning |
| --- | --- |
| `--config <file>` | The settings file (section 2); default `wincode.yaml` in the current folder |
| `--json` | stdout gets one JSON object when the command ends, and nothing else: `command`, `ok`, `exitCode`, the command's results, and on a failure `error` with `id`, `what`, `why` and `next`. Everything meant for people goes to stderr |
| `--verbose` | Also print each step, each external command and each HTTP request (method, host, path, status, time), redacted as section 7 says |
| `--dry-run` | Send nothing, write nothing, start nothing: no request to Apple or GitHub, no file, no zsign run. Print what would be done, with the requests as they would go out |

**Exit codes,** the values of sysexits.h, so 64 keeps the meaning `doctor` gave it:

| Code | Meaning |
| --- | --- |
| 0 | Done |
| 1 | The work failed: a check found a problem, an input is wrong, or Apple or GitHub refused the work |
| 64 | The command line is wrong, or the command is not implemented yet |
| 69 | Something winCode needs is not there: a tool (zsign, `gh`), the SDK, or the network |
| 70 | A bug in winCode; the message asks for a report |
| 77 | Apple or GitHub refused the credentials (HTTP 401 or 403, `gh` not logged in) |
| 78 | The setup is wrong: `wincode.yaml`, or an environment variable that winCode reads |

There is no exit code per failure: the `id` in the `--json` output tells failures apart within a code.

### 2. Settings: `wincode.yaml`

```yaml
# wincode.yaml: one app, no secrets. Paths are relative to this file.
bundle_id: com.example.app
team_id: TEAM000000
profile: ../signing/App_Store.mobileprovision
entitlements: ios/Runner/Runner.entitlements
workflow: example-org/example-app/.github/workflows/wincode-ios.yml@main
output: build/wincode
```

| Key | Needed by | What it is | Checked when the file is loaded |
| --- | --- | --- | --- |
| `bundle_id` | every command that reads the file | The app being shipped. `build`, `sign`, `preflight` and `upload` check that the IPA, the profile and the app record all name it, so a build of another flavor or app never reaches this app record | Letters, digits and hyphens in two or more parts joined by dots |
| `team_id` | every command that reads the file | The team that the profile must belong to | 10 capital letters and digits |
| `profile` | `sign` | The App Store profile, as the developer portal delivers it | Ends in `.mobileprovision` |
| `entitlements` | `sign`, when the app has an `.entitlements` file | The app's own entitlements, signed with the four keys of ADR-0011 rule 6 | Ends in `.entitlements` or `.plist` |
| `workflow` | `build` | The workflow at a branch or tag, written as GitHub writes it: `<owner>/<repository>/.github/workflows/<file>@<ref>` | That shape |
| `output` | `build`, `sign` | Where `unsigned.ipa` and `signed.ipa` go; default `build/wincode`, which Flutter's own `.gitignore` already leaves out | Not empty |

- **No secrets, by construction.** Every value has a fixed shape, so there is no free-text field that a key could go into. An unknown key is refused, so a misspelled one is not silently ignored. A key whose name looks like a secret (it contains `key`, `secret`, `pass`, `token`, `issuer`, `credential`, `p8` or `p12`) gets its own message, which names the environment variables. A message names the key, never the value.
- **Text only.** YAML reads `team_id: 0123456789` as a number and drops the zero, so every value must be a string, and the message says to quote it.
- **Paths** are relative to the file. The files are opened by the command that uses them, not when the settings are loaded, so `init` and `doctor` work before the profile exists.
- **One file per app identity.** A project with flavors keeps one file per flavor that ships, chosen with `--config`.
- **No key for the certificate.** `sign` takes it from the profile, whose `DeveloperCertificates` holds every certificate the profile was made for, by matching its public key with the distribution key. The spike kept a separate `.cer`; this removes a file that had to be downloaded and kept in step with the profile.
- **The profile is not a secret,** but it names the team, so it is better kept out of a public repository.

**Secrets come only from environment variables,** the ones the spike scripts already use. Each names a file or folder outside the project and outside OneDrive, and the commands refuse both, as the scripts do.

| Variable | What it names | Read by |
| --- | --- | --- |
| `WINCODE_ASC_KEY_DIR` | A folder with `AuthKey_<Key ID>.p8` as App Store Connect delivers it, and `issuer-id`, a file that holds the Issuer ID | `preflight`, `upload`, `status` |
| `WINCODE_DIST_KEY` | The distribution private key (PEM) on the WSL2 disk; a path under `/mnt/` is refused | `sign` |
| `ZSIGN` | Optional: a zsign other than the pinned one (section 4) | `sign` |

The OS credential store that ADR-0009 names, Windows Credential Manager, is not used in these phases: files named by variables are what the scripts used for every real upload. Moving the keys there is a later change with its own decision, and it never makes `wincode.yaml` hold a secret.

### 3. Build: the macOS runner

**`wincode build` drives GitHub through the GitHub CLI (`gh`), not the REST API.** `gh` keeps the user's GitHub login in its own credential store, so winCode never holds a GitHub token. The REST API would need one, with the Actions permission to read and write, and winCode would have to store it, redact it and tell the user when to renew it.

1. **Check:** `gh` is installed (else 69) and logged in, `gh auth status` (else 77).
2. **Start:** `gh workflow run <file> --repo <owner>/<repository> --ref <ref> -f request_id=<random>`.
3. **Find the run:** `gh` prints the new run's URL when GitHub returns it ("if available", says the help of `gh` 2.102.0), and winCode reads the run ID from it. Otherwise winCode lists the workflow's runs (`gh run list --workflow <file> --event workflow_dispatch --json databaseId,displayTitle,headSha,status`) until one titled `wincode <request_id>` appears, for up to 2 minutes.
4. **Wait:** `gh run watch <id> --exit-status`, with its progress on stderr.
5. **Download:** `gh run download <id> --name unsigned-ipa --dir <temporary folder>`.
6. **Check:** exactly one `.ipa` holding exactly one `Payload/<name>.app`, whose `CFBundleIdentifier` is `bundle_id`, and no `embedded.mobileprovision`, since it must be unsigned. It then moves to `<output>/unsigned.ipa`, and the run's URL and commit go into the `--json` result.

**What the app's workflow must do:**

- start on `workflow_dispatch` with a string input `request_id`, and carry it in its run name, `wincode ${{ inputs.request_id }}`;
- build with a final Xcode 26 or later, the version that App Store Connect requires (`docs/PLAN.md`, "Zero-rejection checks");
- upload one artifact named `unsigned-ipa` that holds one `.ipa` with `Payload/<name>.app`;
- sign nothing and hold no Apple secret: no certificate, profile or App Store Connect key on the runner;
- run only on a dispatch, never for a pull request, because macOS minutes are the scarce ones.

**The reference workflow** is [`packages/wincode_cli/templates/wincode-ios.yml`](../../packages/wincode_cli/templates/wincode-ios.yml). It checks out the app, selects Xcode, clones Flutter at the app's release, runs `flutter build ipa --release --no-codesign` (with `--flavor` when one is set), packs the archive's `.app` into `Payload/`, and uploads it with a retention of one day. In a public repository anyone who can read the repository can download the IPA until then. Its actions are pinned to commits, as winCode's own workflows are. `wincode init` writes it from phase 5.

### 4. Sign: wrap zsign, in WSL2

**`wincode sign` runs zsign and puts winCode's own checks around it. winCode does not sign in Dart.**

- **Why zsign:** Apple has processed IPAs signed this way as valid, from spike C to the real apps of the hybrid lane. zsign is MIT-licensed, and it is the signer that xtool already uses (ADR-0001).
- **Why not Dart:** writing a signature means the whole format: code directories with page hashes, requirements, the entitlements as XML and as DER, a CMS signature with Apple's hash attributes, `_CodeSignature/CodeResources` with the hash of every resource, and room for all of it in each Mach-O's `__LINKEDIT`. That is a large Apple format, so CONTRIBUTING.md asks for a spec in `docs/formats/` first and an oracle on macOS, and the result would replace a signer whose output Apple already accepts. The part winCode does write in Dart is the read-back below, which is also the first half of a signer if one is ever needed.
- **Where:** zsign runs inside WSL2, as ADR-0001 decided and as the spike ran it. `wincode sign` calls it through `wincode_core`'s `wslRunner`, with the paths converted by `toWslPath`. The distribution key stays on the WSL2 disk.
- **Pin policy,** from `build-zsign.sh`, which becomes a step of `tools/setup-wsl-toolchain.sh`:
  - the source is the commit that xtool pins, `xtool-org/zsign` 1.9.0 (`f6158be9`), and the build stops if `third_party/xtool/Package.resolved` pins another one, so zsign moves only with xtool;
  - GitHub's archive of that commit is checked against its SHA-256 (`423ebe2f…`) before anything is built;
  - it is built from source on the user's PC with Ubuntu's `make` and `libssl-dev` and the Swift toolchain's clang, so OpenSSL comes with Ubuntu's security updates;
  - `wincode sign` checks that `zsign --version` prints the pinned version, and refuses another zsign unless `ZSIGN` names it, which it then says on every run.

  Nothing is downloaded when signing.
- **Licences:** zsign is MIT. It compiles its own copies of zlib and minizip (zlib licence) and links OpenSSL 3 (Apache-2.0). winCode ships none of them in this design, since each user builds zsign. If winCode ever ships a zsign binary, those three notices ship with it.
- **The checks around zsign,** ported from `sign.py`:
  - **Before:** the profile is an App Store profile (no devices, no `get-task-allow`) for `team_id` and `bundle_id`, and has not expired; one of its certificates is a distribution certificate for the key in `WINCODE_DIST_KEY`, and has not expired; the IPA's bundle ID is `bundle_id`.
  - **Entitlements:** the four keys of ADR-0011 rule 6, plus the keys of `entitlements`, each allowed by the profile: equal, or matched by the profile's trailing `*`.
  - **After:** every Mach-O is signed; the main executable carries exactly those entitlements and every framework none; `embedded.mobileprovision` is there; the IPA holds only `Payload/`; zsign is stopped if its files pass 1 GB.
- **A native Windows zsign is not chosen for now.** The pinned commit's Windows project links prebuilt OpenSSL libraries kept in zsign's own repository (`build/windows/vs2022/lib/openssl`: `libcrypto.lib` and `libssl.lib`), which winCode cannot trace to a source. Shipping a binary would also make winCode the distributor of a signing tool, with its notices, its provenance, and Windows Defender's view of an unsigned program that rewrites binaries (Defender blocked the xcross binary, `docs/PLAN.md`). If users of the hybrid lane without WSL2 need one, the route is:
  1. winCode's CI builds zsign on a Windows runner from the pinned commit, against an OpenSSL that winCode pins;
  2. it publishes the binary with its SHA-256 and a provenance attestation, and `wincode` pins that hash;
  3. the binary is used only after it signs the same bundle with the same code directory hashes as the WSL2 build, and one IPA it signed is processed as valid.

### 5. The three scripts: port to Dart in stages

| Option | Cost | Risk |
| --- | --- | --- |
| **A. Keep Python behind the CLI**: `wincode preflight` runs `asc_preflight.py` | The least: glue code that runs the scripts | Every Windows user needs Python 3, `cryptography` and `openssl`, which is what this ADR must avoid. The scripts' setup (`config.json`, `WINCODE_SPIKE_C_DIR`) needs rewriting anyway, two languages need two test setups, and the scripts must ship next to a compiled `wincode.exe` |
| **B. Port all three at once** | All of the porting in one go: about 750 lines of Python (`asc_preflight.py` 322, `asc_upload.py` 188, `sign.py` 240), plus the signature reading in `tools/ipa-diff` | Three new implementations replace three proven ones together. A fault in any of them stops the lane, and it is harder to tell which one |
| **C. Port in stages** (chosen) | The same total as B, one script per phase: preflight (phase 2), sign (3), upload (4) | One new piece per phase, checked against its script on the same inputs before it replaces it. The scripts stay as they are in `spikes/` until then, so the lane never stops |

**C is chosen.** The CLI never calls a script: a step that is not ported yet is simply not implemented in it, so no Windows user ever needs Python. The order goes from the least to the most risky: `preflight` sends GET requests only, `sign` writes only a local file, and `upload` is the one write to Apple.

- **Where the code goes:** the App Store Connect client (the ES256 token, paged GET requests, build uploads) in `packages/wincode_asc`, as ADR-0009 planned; the profile and entitlements checks in `packages/wincode_core`, next to `buildEntitlements`; the commands, `gh` and zsign in `packages/wincode_cli`.
- **New dependencies,** pure Dart with permissive licences: `args` and `yaml` (phase 1); `pointycastle` for ES256 and `archive` to read the IPA (phase 2); `crypto` for the upload's MD5 (phase 4). HTTP uses `dart:io`.
- **Once a phase is accepted,** its script stays in `spikes/` as the record of spike C and is no longer the way to ship.

### 6. Error model

Every failure says what happened, why, and the exact next step, on stderr:

```
wincode <command>: <what happened>
  why: <why it matters, or what usually causes it>
  next: <the exact next step>
```

- Each failure also has a stable `id`, used by `--json`, and one exit code from section 1.
- Apple's and GitHub's own words (an error's `code`, `title` and `detail`; a run's conclusion) are quoted as sent, after the redaction of section 7.
- There is no stack trace unless `--verbose` is on, and then only for a bug (70).
- Until a command is implemented, it prints `wincode <command>: not implemented yet, see ADR-0013` and exits 64.

The ten most likely failures, with `<…>` filled in at run time:

1. **Expired profile** (`profile-expired`, exit 1; `sign`, `preflight`):

   ```
   wincode sign: the profile expired on <date>
     why: Apple refuses a build signed with an expired profile, and zsign would sign with it anyway.
     next: make a new App Store profile for <bundle ID> in the developer portal (Profiles), download it, and point profile in wincode.yaml at it.
   ```

2. **Build number not higher** (`build-number-not-higher`, exit 1; `preflight`, `upload`). As in the script's check of PR #11, the number is compared with every build of the app, not only the builds of the same version: stricter than Apple's rule, and it only ever costs a build number.

   ```
   wincode preflight: build <n> is not higher than <highest>, the highest build App Store Connect has for this app
     why: Apple refuses a build number it has already seen, and a used number stays used even when its build failed.
     next: raise the build number above <highest> (version: x.y.z+N in pubspec.yaml), then build and sign again.
   ```

3. **Wrong bundle ID** (`bundle-id-mismatch`, exit 1; `build`, `sign`, `preflight`). The profile's variant says "the profile is for <bundle ID>", and its next step is to download the profile made for `bundle_id`.

   ```
   wincode sign: the IPA's bundle ID is <IPA's>, but wincode.yaml says <configured>
     why: winCode signs and uploads only the app that wincode.yaml names, so a build of another flavor or app cannot reach this app record.
     next: build the flavor whose bundle ID is <configured>, or use the wincode.yaml of <IPA's> (--config).
   ```

4. **Missing entitlement** (`entitlement-not-allowed`, exit 1; `sign`):

   ```
   wincode sign: the app's entitlements ask for <key>, which the profile does not allow
     why: iOS and Apple's checks refuse an app whose signature claims an entitlement that its profile does not grant.
     next: turn on the capability for the App ID <bundle ID> in the developer portal (Identifiers), then make and download the App Store profile again; or remove <key> from <entitlements file> if the app does not use it.
   ```

   Its twin is `entitlements-missing` (exit 78): the project has an `.entitlements` file in `ios/Runner` but `wincode.yaml` names none, so the signed app would lack its entitlements, and a feature such as Sign in with Apple would fail only on the device. The next step is to add `entitlements:` with that file.

5. **Apple API 401 or 403** (`asc-unauthorized` or `asc-forbidden`, exit 77; `preflight`, `upload`, `status`):

   ```
   wincode preflight: App Store Connect refused the API key: HTTP 401 NOT_AUTHORIZED
     why: the key was revoked, the Key ID or the Issuer ID does not belong to the .p8, or this PC's clock is off by minutes (the token carries the time).
     next: check that WINCODE_ASC_KEY_DIR holds AuthKey_<Key ID>.p8 as downloaded and issuer-id with the Issuer ID (Users and Access, Integrations); set the clock right; make a new key if this one was revoked.
   ```

   For a 403, the why is "the key's role may not do this, or an agreement waits to be accepted in App Store Connect", and the next step is "accept the agreements (Business), or use a key whose role may upload builds".

6. **zsign missing** (`zsign-missing`, exit 69; `sign`):

   ```
   wincode sign: zsign is not installed in WSL2
     why: winCode signs with the zsign of the commit that xtool pins, built on this PC from its checked source.
     next: run tools/setup-wsl-toolchain.sh in WSL2, which builds it; or set ZSIGN to a zsign built from commit f6158be9.
   ```

7. **Runner artifact missing** (`artifact-missing`, exit 1; `build`):

   ```
   wincode build: run <URL> ended (<conclusion>) without an artifact named unsigned-ipa
     why: the workflow failed before its upload step, uploaded the IPA under another name, or the artifact has expired.
     next: read the run's log at <URL>, compare the workflow with the reference one that wincode init writes, then run wincode build again.
   ```

8. **Offline** (`offline`, exit 69; every command that reaches Apple or GitHub). During an upload, the last sentence becomes "The last request may or may not have reached Apple: run wincode status before uploading again."

   ```
   wincode preflight: cannot reach api.appstoreconnect.apple.com: <the system's message>
     why: there is no network, a proxy or a firewall is in the way, or Apple's service is down.
     next: check the connection (and HTTPS_PROXY, if you use one) and Apple's system status page, then run the command again. Nothing was sent.
   ```

9. **Duplicate upload** (`upload-refused`, exit 1; `upload`), when another upload of the same build number got there after the preflight looked:

   ```
   wincode upload: App Store Connect refused the upload: <Apple's code and detail, as sent>
     why: version <version> build <n> was uploaded already, from this PC or elsewhere; a build number stays used even when its processing fails.
     next: run wincode status to see that upload. To send this build anyway, raise the build number, then build and sign again.
   ```

10. **SDK missing, for `doctor`** (`sdk-missing`, exit 69). This one is implemented in phase 1.

    ```
    wincode doctor: <folder> is not an iPhoneOS SDK folder: it has no SDKSettings.json
      why: --sdk names the iPhoneOS.sdk that `xtool sdk` builds in WSL2 from your own Xcode.xip. winCode ships no SDK files.
      next: build it with tools/setup-wsl-toolchain.sh in WSL2, then pass \\wsl.localhost\<distribution>\home\<user>\.swiftpm\swift-sdks\darwin.artifactbundle\Developer\Platforms\iPhoneOS.platform\Developer\SDKs\iPhoneOS.sdk
    ```

### 7. Security

- **Key material** is read only from the files that the variables name, outside the project and outside OneDrive. winCode never copies, caches or writes it. `--dry-run` checks the key when its variable is set, as the scripts do, and sends nothing.
- **Never printed, with or without `--verbose`:** the contents of the key files, the token, the Key ID, the Issuer ID, the values of `WINCODE_ASC_KEY_DIR` and `WINCODE_DIST_KEY` (a message names the variable, never the path), the signed URLs of the upload parts, and any `Authorization` header. winCode holds no GitHub token at all.
- **One redactor** sits in front of stdout and stderr and replaces those values wherever they appear, including inside Apple's error text and inside exception messages. `--verbose` adds lines, and they go through the same redactor. Request bodies are printed: they hold the app record's ID, the version, the build number, and the file's name, size and checksum, nothing secret.
- **Shown:** the bundle ID and the team ID. Every signed IPA carries both, and the messages of section 6 need them to say what is wrong. The spike scripts masked them because their output went into this repository; the CLI's output goes to the user.
- **The token** is ES256 with a lifetime of 10 minutes (Apple refuses more than 20), and a new one is made for each request. It is sent only to `api.appstoreconnect.apple.com`, never after a redirect, and never to the upload URLs.
- **Temporary files:** zsign's entitlements and the certificate taken from the profile go to a temporary folder that is deleted after the run. The key is passed to zsign by its path, never copied.
- **Writes:** only `upload` writes to Apple. As in `asc_upload.py`, nothing is retried after an error, because a repeated request could make a second upload.
- **Supply chain:** zsign as in section 4; `gh` is the user's own install; the Dart dependencies are the pure-Dart packages of section 5.

### 8. Tests

- **No network in CI:** `dart test` reaches no server.
  - App Store Connect is a fake HTTP server on `127.0.0.1` (`dart:io`) that answers in the shapes of Apple's OpenAPI spec 4.5.1, with made-up IDs. The client takes its base URL as a parameter.
  - GitHub is a fake `gh` and zsign a fake zsign, both through `wincode_core`'s `RunProcess`, with canned output and exit codes.
- **The cases:** those that spike C ran `asc_upload.py` through against a fake Apple (a normal run, a refused create, a refused part, a refused commit, failed processing, the 15-minute stop), and those of sections 6 and 7 (401, 403, a connection lost during an upload, paging through `links.next`, a redirect that must not carry the token).
- **Golden outputs:** `--help` (phase 1), each command's `--dry-run` requests, the messages of section 6 and the `--json` objects are compared byte for byte with files in `test/goldens`. `UPDATE_GOLDENS=1 dart test` rewrites them, and the pull request shows the diff.
- **Known answers, not trust:** the ES256 signature is checked against the P-256 and SHA-256 test vectors of RFC 6979 (deterministic signatures), so the test does not rely on the library that signs. The token's header and claims are checked field by field, as the script's self-test does.
- **No secret in any output:** each test that loads a key checks that its whole output holds no token, Key ID, Issuer ID or key path.
- **Parity with the scripts:** before a command replaces its script, both run on the same inputs: the same requests from `--dry-run`, and for `sign` the same entitlements and read-back results with a throwaway identity, as in spike C's offline signing run.
- **Real runs** are made by hand and recorded in the pull request without IDs; an upload only with the maintainer's yes.
- **Where:** from phase 2, `dart.yml`'s matrix adds `wincode_asc`, and runs `wincode_cli` on a Windows runner too, because paths and process calls differ there. No macOS job.

### 9. Out of scope

- The `Assets.car` compiler, or any other compiler of an Apple format: that is the `Assets.car` track of `docs/PLAN.md` (ADR-0012).
- Building the Darwin SDK, or a store build on Windows. `wincode build` builds in the cloud Mac lane; a pure-Windows build is later another lane of the same command (ADR-0008), not part of these phases.
- App Review and TestFlight automation: submitting for review, metadata, screenshots, testers and groups, releasing.
- Making certificates, profiles, App IDs or app records, which ADR-0009 leaves to the user for now; Transporter.
- `wincode ship` (ADR-0008), a command that chains `build`, `sign` and `upload` once each of them works.

### 10. Phases

**Phase 1, this change: the skeleton.**
- Every command of section 1 is registered; the six that are not implemented print `not implemented yet, see ADR-0013` and exit 64.
- The global options, the exit codes of section 1 as constants, and the three-line errors, also in `--json`.
- `wincode.yaml` is loaded and checked as section 2 says, without opening the files it names.
- `doctor` keeps its checks, uses the error model, and exits 69 for a folder that is not an SDK (it was 1).
- Tests: the settings file, the `--help` golden, `--json`, and the global options on both sides of the command.

**Phase 2: `preflight` in Dart, and `init`.** Accepted when:
- `packages/wincode_asc` holds the token and the paged GET requests, and the ES256 known-answer test passes;
- for the same app, `wincode preflight --dry-run` prints the GET requests of its three checks as `asc_preflight.py --dry-run` prints them (golden);
- against the fake server, the three checks pass and fail where the script's do, including the build-number cases that PR #11 adds to the script's self-test, and each local check of the IPA (bundle ID, version, build number, profile, expiry) has a test;
- no test's output holds the key, the token, the Key ID or the Issuer ID;
- one real run on the test app record, read-only, gives the same PASS and FAIL lines as the script;
- `wincode init` writes `wincode.yaml` for the flavored sample in `wincode_core`'s test fixtures, and refuses to overwrite one;
- CI runs `wincode_asc`, and `wincode_cli` on Windows too.

**Phase 3: `sign`.** Accepted when:
- each check of section 4 has a test, with a throwaway CA, identity and profile, and a fake zsign;
- the read-back is in Dart (the entitlements blob of the code signature that `LC_CODE_SIGNATURE` points to), with its format notes in `docs/formats/` first;
- the setup script builds the pinned zsign, and `wincode sign` refuses another one unless `ZSIGN` names it;
- with the same unsigned bundle and throwaway identity, `wincode sign` and `sign.py` sign the same entitlements into each binary, and both read-backs pass;
- a hybrid-lane IPA signed by `wincode sign` is uploaded, with the maintainer's yes, and processed as valid.

**Phase 4: `upload` and `status`.** Accepted when:
- the fake-server cases of section 8 pass: nothing is retried, the parts rebuild the IPA byte for byte, the token never goes to a part's URL, and no hidden value is printed;
- `wincode upload --dry-run` prints the same requests as `asc_upload.py --dry-run` (golden);
- `upload` runs `preflight` first and stops when it fails;
- one real upload, with the maintainer's yes, is processed as valid, and its output shows the same steps as spike C's run; `wincode status` then shows it.

**Phase 5: `build`.** Accepted when:
- against a fake `gh`, the run is found by its URL and by its title, waited for and downloaded, and each failure gives its message: `gh` missing (69), not logged in (77), a failed run (1), a missing artifact (1), a wrong bundle ID (1);
- the reference workflow passes actionlint, and `wincode init` writes it byte for byte (golden);
- on a test app's repository, `wincode build`, `wincode sign` and `wincode upload` in a row end with a build processed as valid, using macOS minutes and an upload that the maintainer says yes to.

## Consequences

- **Windows users need no Python.** `build` needs `gh` and a GitHub repository. `sign` needs WSL2 with the pinned zsign, so a user of the hybrid lane installs WSL2 only to sign, until a native zsign or a Dart signer replaces it.
- **The spike scripts keep working** until each phase replaces them, and then stay as spike C's record.
- **`doctor` changes a little:** its errors use the three-line form on stderr, a usage error goes to stderr, and a folder that is not an SDK exits 69 instead of 1.
- **ADR-0008's `wincode ship --lane mac`** becomes `build`, `sign` and `upload`; a `ship` that chains them is still possible later.
- **ADR-0009's Windows Credential Manager waits:** the variables of section 2 hold until a decision moves the keys.
- **To revisit:** where zsign runs (WSL2, a native build, or Dart) once hybrid-lane users without WSL2 appear; the credential store; the build-number rule, if Apple's per-version rule is confirmed on a test app.

## Alternatives considered

- **The REST API instead of `gh`:** no extra tool, but winCode would hold, store and redact a GitHub token. `gh` is one install and keeps the login itself.
- **Keeping Python behind the CLI (A), or porting everything at once (B):** section 5.
- **A Dart signer, or a native Windows zsign now:** section 4.
- **JSON or TOML for the settings:** Flutter projects already use YAML (`pubspec.yaml`), and YAML takes comments, which `init` uses to explain each key.
- **Secrets in `wincode.yaml`, even encrypted:** the file goes with the project, and an encrypted secret still needs a key from somewhere else, which is what the variables are.
- **An exit code per failure:** too many to remember; the `id` in `--json` tells failures apart.
- **A question before `upload`:** running `upload` is the decision, `--dry-run` shows what it would send, and the preflight runs first. A prompt would also stop CI.

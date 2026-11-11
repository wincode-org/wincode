# 0013. wincode CLI: build, sign, upload

- Status: Proposed
- Date: 2026-11-08
- Amended: 2026-11-08, after review: zsign in WSL2 is interim (section 4), the key-location rule (section 2), `--redact` and redaction in CI (sections 1 and 7), the `doctor` changes (Consequences)
- Amended by [ADR-0014](0014-one-project-many-apps.md) (Accepted): several apps in one `wincode.yaml`, a credentials reference per app, `--app` and `--all`; and the distribution key lives on the Windows side, not on the WSL2 disk (sections 2 and 4 below)

## Context

- **The hybrid lane is how real apps ship today** (ADR-0008, ADR-0012). A hosted macOS runner in the app's own GitHub repository builds an unsigned IPA with Xcode. On Windows the IPA is signed with zsign (ADR-0009, ADR-0011), checked against App Store Connect, and uploaded through the Build Uploads API. Builds of real apps with third-party sign-in and a payments SDK have reached TestFlight this way.
- **The Windows half is three spike scripts** in `spikes/c-store-acceptance`, in Python:
  - `sign.py` checks the certificate, the profile and the entitlements against each other, signs with zsign, and reads every signature back;
  - `asc_preflight.py` makes GET-only checks (the key works, the app record exists, the build number is above every existing build's, since PR #11) and lists the team's certificates and profiles;
  - `asc_upload.py` drives the Build Uploads API, from creating the upload to Apple's processing result.
- **What the scripts need:** Python 3 with the `cryptography` package, `openssl`, zsign built in WSL2, a `config.json` and three environment variables. The macOS half is a workflow file that each app's repository holds, started and downloaded by hand.
- **`wincode` has one command,** `doctor` (Mach-O checks), with its own argument parsing and exit codes 0, 1 and 64.
- **Windows users must not need Python.** They install Flutter, which brings Dart (ADR-0002); the CLI is one Dart executable.

## Decision

### 1. Commands

`wincode <command> [arguments]`. The lane is `wincode build`, then `wincode sign`, then `wincode upload`, and each step also runs alone.

| Command | What it does | Talks to | Phase |
| --- | --- | --- | --- |
| `init` | Writes a commented `wincode.yaml` for the Flutter project in the current folder, from `ios/Runner.xcodeproj` and its xcconfig files, read by `wincode_core`'s flavor reader (`--flavor` for one flavor). With `--workflow` it also copies the reference workflow, and it never replaces that file. It replaces `wincode.yaml` only with `--force` | nothing | 2 |
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
| `--redact` | Hide the bundle ID and the team ID in everything printed. Always on when the `CI` environment variable is set (not empty, `0` or `false`). Section 7 |
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
- **The build configuration is not a setting.** `wincode.yaml` has no key for the Xcode configuration that `init` read the bundle ID from; `wincode init --configuration <name>` takes it on the command line. Nothing else reads the Xcode project, so nothing else needs it. *ADR-0014 changes this: a file of apps records `flavor` and `configuration` per app, and a flat file may too.*
- **No key for the certificate.** `sign` takes it from the profile, whose `DeveloperCertificates` holds every certificate the profile was made for, by matching its public key with the distribution key. The spike kept a separate `.cer`; this removes a file that had to be downloaded and kept in step with the profile.
- **The profile is not a secret,** but it names the team, so it is better kept out of a public repository.

**Secrets come only from environment variables,** the ones the spike scripts already use. Each names a file or folder outside the project and outside OneDrive, and the commands refuse both, as the scripts do. This holds through phase 5.

| Variable | What it names | Read by |
| --- | --- | --- |
| `WINCODE_ASC_KEY_DIR` | A folder with `AuthKey_<Key ID>.p8` as App Store Connect delivers it, and `issuer-id`, a file that holds the Issuer ID | `preflight`, `upload`, `status` |
| `WINCODE_DIST_KEY` | The distribution private key (PEM), a file on a Windows drive. `sign` reads it in place: zsign gets its path as `wslpath -u` translates it (section 4), and nothing key-related is written inside WSL2. *Amended by ADR-0014: this was a file on the WSL2 disk with a path under `/mnt/` refused, which is what the spike's `sign.py` still does until `wincode sign` replaces it.* | `sign` |
| `ZSIGN` | Optional: a zsign other than the pinned one (section 4). *Not built: phase 3a runs only the pinned zsign, at a fixed path (phase 3a as built, section 10).* | `sign` |
| `WINCODE_WSL_DISTRO` | Optional, added in phase 3a: the WSL2 distribution where zsign is built. Unset, `wsl.exe` uses its default one | `sign`, `doctor --sign` |

**No key or profile lies in a git working tree,** unless git ignores it. The commands refuse every such file (the `.p8`, `issuer-id`, the distribution key, and `profile`) that lies inside a git working tree unless `git check-ignore` reports it as ignored; a file that git tracks is never ignored. `git rev-parse --is-inside-work-tree` tells whether the file is in a tree and `git check-ignore -q` whether it is ignored, both run in the file's folder, with Git for Windows. When git cannot run, the file is refused too (69, `git-unavailable`). The message names the variable or the key, never the path, and says what to move and where (exit 78, `key-in-git-tree`):

```
wincode sign: WINCODE_DIST_KEY points inside a git working tree, and git does not ignore the file
  why: a key or profile there can be committed and pushed with the project, and it stays in the history after it is deleted.
  next: move the file outside every project folder, such as %USERPROFILE%\.wincode, and point WINCODE_DIST_KEY at the new place. A file that has to stay may be listed in the project's .gitignore, but git check-ignore must report it as ignored.
```

The check is `requireOutsideGit` in `packages/wincode_cli`, tested with a real repository (tracked, ignored, outside) and with a missing or failing git. `preflight` and `init` call it (phase 2); `sign` does too (phase 3a).

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
- **Where, an interim decision:** zsign runs inside WSL2, as ADR-0001 decided and as the spike ran it. It is the signer that has been verified, not the final answer: a native Windows build is the follow-up F1 (section 10), after phase 4. `wincode sign` calls zsign through `wincode_core`'s `wslRunner` (*as built: through `wsl.exe [-d <distribution>] --exec`, so that no shell reads the arguments; phase 3a as built*). The distribution key stays on the Windows side (amended by ADR-0014): zsign reads it in place through `/mnt/<drive>`, and nothing key-related is written to the WSL2 disk. A key on a path that `wslpath` cannot translate (a network share, a drive that WSL2 does not mount) fails with `dist-key-unreachable` (78) and the next step to move it to a local drive.
  - **Paths** go to WSL2 translated by `wslpath -u`, run in the distribution, not by rewriting the string. `wslpath` knows drive letters and a changed automount root; `toWslPath` of `wincode_core` knows only `C:\` becoming `/mnt/c/` and refuses the rest. `toWslPath` stays for code that cannot run a process. *Corrected in phase 3a: `wslpath -u` does not know `\\wsl.localhost\<distribution>\…` paths. On Ubuntu 24.04 it turned `\\wsl.localhost\<distribution>\etc\hostname` into `/mnt/c/wsl.localhost/<distribution>/etc/hostname`, a path that does not exist. `wincode sign` therefore never gives `wslpath` a UNC path: one is untranslatable, and the key behind one fails with `dist-key-unreachable`.*
  - **`wincode doctor` checks the setup** (added in phase 3), each failure with its next step:

    ```
    wincode doctor: WSL2 has no Linux distribution
      why: wincode sign runs zsign inside WSL2 (ADR-0013, section 4).
      next: run `wsl --install -d Ubuntu` in an administrator terminal and restart, then run tools/setup-wsl-toolchain.sh in WSL2.
    ```

    ```
    wincode doctor: the zsign in WSL2 is not the one winCode pins
      why: wincode sign signs the app with it, and a changed binary could sign anything. It prints version <found>, not 1.9.0 (f6158be9), or its SHA-256 is not the one tools/setup-wsl-toolchain.sh recorded when it built it.
      next: run tools/setup-wsl-toolchain.sh in WSL2 to build it again from the checked source.
    ```

    The first is `wsl-missing` (69) and the second `zsign-changed` (1); `zsign-missing` is in section 6. The setup script checks the SHA-256 of the pinned source archive when it builds, and writes the SHA-256 of the binary it made next to it. A built binary differs between toolchains, so only that local record, not the repository, can pin it. *As built in phase 3a: these checks are `wincode doctor --sign`. No setup script builds zsign: `doctor --sign` prints the commands, the user runs them, and the first `doctor --sign` that finds the binary records its SHA-256 outside the repository (phase 3a as built, section 10).*
- **The key's password never goes on a command line.** Read in the pinned source (`src/zsign.cpp`, `src/openssl.cpp`): zsign takes the password of a private key or `.p12` only as the argument `-p`. It reads no environment variable and no standard input. An argument is visible to every program of the same user, in the Windows process list (the `wsl.exe` command line carries it) and in WSL2's, and a log may keep it. So:
  - `wincode sign` never passes `-p`. The verified flow needs none: `WINCODE_DIST_KEY` is an unencrypted PEM key on a Windows drive and the certificate is a separate file, and `-k` and `-c` take paths. A `.p12`, or a key that needs a password, is refused (78, `key-encrypted`) with the step the spike used: keep the working key unencrypted and the encrypted backup elsewhere.
  - No password is logged or written to a file (section 7).
  - **Open risk:** the unencrypted working key sits in the user's Windows profile (ADR-0014 puts the keys root there; it was the WSL2 disk), where the user's own programs read it and profile backups copy it. It is no longer in a distribution that `wsl --export` snapshots. **Mitigation, for a later change:** encrypted keys come later: keep the key encrypted, and have `wincode sign` ask for the password on the terminal (never as an argument), decrypt the key with `openssl pkey -passin stdin` into a file of mode 0600 in a private folder of the WSL2 tmpfs (`$XDG_RUNTIME_DIR`, else `/dev/shm`), pass that path to zsign, and delete the file when zsign ends. This private tmpfs copy, in memory and gone after the run, is the only place a key may appear inside WSL2. The password then lives only in winCode's memory, and the exposure shrinks to the decrypted file during the run. Phase 3 does not need it: it signs with the unencrypted key in place.
  - **Decided with the maintainer for phase 3a:** the risk is accepted for now. Phase 3a signs only with an unencrypted PEM key read in place on the Windows side; an encrypted PEM key or a `.p12` is refused with `key-encrypted` (78), whose message says that encrypted keys come in phase 3b. Phase 3b (section 10) is the mitigation above.
- **Pin policy,** from `build-zsign.sh`, which becomes a step of `tools/setup-wsl-toolchain.sh`:
  - the source is the commit that xtool pins, `xtool-org/zsign` 1.9.0 (`f6158be9`), and the build stops if `third_party/xtool/Package.resolved` pins another one, so zsign moves only with xtool;
  - GitHub's archive of that commit is checked against its SHA-256 (`423ebe2f…`) before anything is built;
  - it is built from source on the user's PC with Ubuntu's `make` and `libssl-dev` and the Swift toolchain's clang, so OpenSSL comes with Ubuntu's security updates;
  - `wincode sign` checks that `zsign --version` prints the pinned version, and refuses another zsign unless `ZSIGN` names it, which it then says on every run.

  Nothing is downloaded when signing. *As built in phase 3a: the user builds zsign with the commands that `doctor --sign` prints, at `~/.wincode/zsign/zsign-<commit>/bin/zsign` in the distribution; `sign` runs only that binary, and only while its SHA-256 is the one `doctor --sign` recorded. There is no `ZSIGN` override, and the `Package.resolved` check is a test instead (phase 3a as built, section 10).*
- **Licences:** zsign is MIT. It compiles its own copies of zlib and minizip (zlib licence) and links OpenSSL 3 (Apache-2.0). winCode ships none of them in this design, since each user builds zsign. If winCode ever ships a zsign binary, those three notices ship with it.
- **The checks around zsign,** ported from `sign.py`:
  - **Before:** the profile is an App Store profile (no devices, no `get-task-allow`) for `team_id` and `bundle_id`, and has not expired; one of its certificates is a distribution certificate for the key in `WINCODE_DIST_KEY`, and has not expired; the IPA's bundle ID is `bundle_id`.
  - **Entitlements:** the four keys of ADR-0011 rule 6, plus the keys of `entitlements`, each allowed by the profile: equal, or matched by the profile's trailing `*`.
  - **After:** every Mach-O is signed; the main executable carries exactly those entitlements and every framework none; `embedded.mobileprovision` is there; the IPA holds only `Payload/`; zsign is stopped if its files pass 1 GB. *As built in phase 3a, the read-back checks every hash as well: [`docs/formats/code-signature-verification.md`](../formats/code-signature-verification.md).*
- **A native Windows zsign is not chosen for now,** and is tracked as follow-up F1. The pinned commit's Windows project links prebuilt OpenSSL libraries kept in zsign's own repository (`build/windows/vs2022/lib/openssl`: `libcrypto.lib` and `libssl.lib`), which winCode cannot trace to a source. Shipping a binary would also make winCode the distributor of a signing tool, with its notices, its provenance, and Windows Defender's view of an unsigned program that rewrites binaries (Defender blocked the xcross binary, `docs/PLAN.md`). If users of the hybrid lane without WSL2 need one, the route is:
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
- **New dependencies,** pure Dart with permissive licences: `args` and `yaml` (phase 1); `pointycastle` for ES256 (phase 2; `archive` was replaced by a reader in `wincode_core`, see "Phase 2 as built"); `crypto` for the upload's MD5 (phase 4). HTTP uses `dart:io`.
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

2. **Build number not higher** (`build-number-not-higher`, exit 1; `preflight`, `upload`). As in the script's check (PR #11), the number is compared with every build of the app, not only the builds of the same version: stricter than Apple's rule, and it only ever costs a build number.

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

   *As built in phase 3a, the first line is "zsign is not installed in `<distribution>`", and the next step is "run wincode doctor --sign, which prints the commands that build it; or set `WINCODE_WSL_DISTRO` to the distribution where it is built."*

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
- **Shown by default:** the bundle ID and the team ID. Every signed IPA carries both, and the messages of section 6 need them to say what is wrong. The spike scripts masked them because their output went into this repository; the CLI's output goes to the user. Three things hide them:
  - the global option `--redact`;
  - the `CI` environment variable, when it is set and is not empty, `0` or `false`: a CI service keeps its logs, and more people can read them;
  - text meant for an issue report, always: the message of an internal error (70), which asks for a report, and the output of any later report command.

  Each command registers every ID it learns (from `wincode.yaml`, the IPA or Apple) with the redactor, which replaces them with `<bundle ID>` and `<team ID>` in everything written to stdout and stderr, `--json` included. It works on whole writes, so commands write whole lines. The skeleton has the option, the `CI` check and the redactor; no command prints an ID yet, so none registers one.
- **Keys stay out of git working trees** unless git ignores them (section 2).
- **The token** is ES256 with a lifetime of 10 minutes (Apple refuses more than 20), and a new one is made for each request. It is sent only to `api.appstoreconnect.apple.com`, never after a redirect, and never to the upload URLs.
- **Temporary files:** zsign's entitlements and the certificate taken from the profile go to a temporary folder that is deleted after the run. The key is passed to zsign by its path, never copied. No password is passed to a process or written to a file (section 4). *As built in phase 3a, the temporary folder is `.wincode-sign-<random>` in the app's output folder, on the Windows side, so nothing is written to the WSL2 disk; it holds the certificate, the entitlements, zsign's work folder and the signed IPA until the checks pass.*
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
- **Key location and redaction:** the key-location check runs against a real repository in a temporary folder (outside it, in it, ignored, tracked) and against a fake git that is missing or fails. Redaction is tested on a sample message with `--redact`, with `CI`, and with neither; with every kind of write to the sink; and for the issue-report text.
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
- Added by the review of this ADR: the global option `--redact`, the redactor and the `CI` check, and `requireOutsideGit`, each with tests and no command calling them yet.

**Phase 2: `preflight` in Dart, and `init`.** Accepted when:
- `preflight` calls `requireOutsideGit` for each file of the key folder and for `profile` before it reads them, with a test in which a key lies in a temporary repository, tracked or not ignored;
- every ID the command learns is registered with the redactor, and a test checks that a run with `--redact`, and one with `CI` set, prints neither ID;
- `packages/wincode_asc` holds the token and the paged GET requests, and the ES256 known-answer test passes;
- for the same app, `wincode preflight --dry-run` prints the GET requests of `asc_preflight.py --dry-run` (golden), except the script's certificates request, which `preflight` does not send, and the `uuid` that its profiles request also asks for, so that profiles can be linked by UUID; this difference is intended;
- against the fake server, the three checks pass and fail where the script's do, including the build-number cases of the script's self-test (PR #11), and each local check of the IPA (bundle ID, version, build number, profile, expiry) has a test;
- no test's output holds the key, the token, the Key ID or the Issuer ID;
- one real run on the test app record, read-only, gives the same PASS and FAIL lines as the script;
- `wincode init` writes `wincode.yaml` for the flavored sample in `wincode_core`'s test fixtures, and refuses to overwrite one;
- CI runs `wincode_asc`, and `wincode_cli` on Windows too.

**Phase 2 as built: `preflight` and `init`.** What `preflight` does, and where it departs from the sections above:
- **The checks,** in the order of the report: `key-location`, `api-key`, `app-record`, `builds` (INFO: how many builds and the highest number), `build-number`, `store-profile`, `local-profile`, `ipa`, `signature` and `profile-link`. Each prints PASS, FAIL, WARN or INFO, with the why and the next step of section 6 under a failure or a warning. A failed request stops only the checks in App Store Connect after it; the checks on the PC always run. The exit code is that of the first failure. A profile that expires within 30 days is a warning and does not fail.
- **The requests** are the script's, with two differences: no `GET /v1/certificates` (the script only listed the certificates in its table, and no check of `preflight` needs them), and `uuid` added to `fields[profiles]` of the profiles request, so that `profile-link` can compare profiles by UUID. `--dry-run` prints the four requests otherwise as the script prints them (golden).
- **The build number** is compared as in PR #11. One difference: a build number of the IPA that is not one to three numbers joined by dots fails in the `ipa` check even when the app has no build yet, which the script let pass.
- **Beyond the script:** the App ID's active App Store profile and its expiry; the profile of `wincode.yaml` (team, bundle ID, App Store distribution, expiry); the IPA (one app in `Payload/`, its bundle ID, its version and its build number). When the IPA holds `embedded.mobileprovision`, that profile is checked the same way, and so is the `application-identifier` signed into the executable, read as `docs/formats/code-signature-entitlements.md` describes. An IPA without it is reported (INFO), not failed: `upload` (phase 4) decides whether to require a signature.
- **Profile linking (`profile-link`):** the `UUID` of the profile in App Store Connect (the App ID's active `IOS_APP_STORE` profile), of the profile file in `wincode.yaml` and of the IPA's `embedded.mobileprovision` must agree, and no UUID is printed. The file must be one of the App ID's active App Store profiles in App Store Connect (`profile-uuid-mismatch` when App Store Connect does not list it, `profile-not-active` when it lists it as another type or state). A signed IPA must carry the file's profile (`ipa-profile-mismatch`), or, when `wincode.yaml` names none, an active App Store profile of the App ID (`ipa-profile-unknown`). All four fail with exit 1. A comparison is made when both of its sides were read.
- **Unsigned IPA:** standalone `preflight` reports an IPA without `embedded.mobileprovision` as INFO, in `signature` and in `profile-link`, so that it can be run on the IPA that `build` downloads. Phase 4 changes this for `upload` (its acceptance criteria).
- **Dependencies:** only `pointycastle`, pinned to exactly 4.0.0 (MIT, pure Dart, last release February 2025). It is the one package that holds an API key, so it is pinned and a change to it needs a review.
  - **All signing stays behind one function,** `AscKey.sign` in `packages/wincode_asc/lib/src/key.dart`: it is the only file in `lib` that imports `pointycastle` (the throwaway key of the tests imports it in `testing.dart`). The RFC 6979 known-answer test checks that function, so a replacement (another package, or `dart:ffi` to the system's crypto) has to pass the same vectors.
  - **`archive` was not added.** What is read by hand instead, each with tests and its limits:
    - **The zip reader** (`wincode_core`, `ZipArchive`): stored and deflated entries only. It refuses Zip64, encryption, several disks, a duplicate entry, a name with `..`, a backslash, a drive letter or an absolute path, and entries whose data overlap. Its limits (`ZipLimits`): 50,000 entries, a 32 MiB directory, 8 GiB claimed in all, and 64 MiB held in memory per read. An entry is inflated in 64 KiB chunks and never past the size its header claims, and `readRange` keeps only the bytes asked for, so the header and the signature of a large executable are read without holding it. Every violation is a format error, reported as `ipa-unreadable` (exit 1), never as an internal error (70).
    - **The profile reader:** the property list is found by its markers inside the CMS; the CMS signature is not checked, as `sign.py` did not check it. It needs `UUID`, `TeamIdentifier`, the application identifier and `ExpirationDate`.
    - **The entitlements read-back** (slot 5 of the code signature, `docs/formats/code-signature-entitlements.md`): a thin 64-bit little-endian Mach-O only, and the hashes are not checked.
    - **The `.p8` reader:** PKCS #8 with an EC P-256 key only, lengths of at most two bytes.
- **HTTP:** a timeout of 20 seconds. A request that gets no answer or HTTP 5xx is tried twice more, after 1 and 2 seconds. `HTTPS_PROXY` applies, as it did for the script.
- **Redaction:**
  - always replaced: the token, the Key ID, the Issuer ID and the key folder's absolute path;
  - replaced with `--redact` or `CI`: the bundle ID and the team ID, those of another app or team that the IPA or a profile names, and Apple's IDs of the app record and the App ID.
- **`--json`:** `checks` holds every finding, each with `check`, `status` and `what`, and with `id`, `why` and `next` for a failure or a warning. `error` holds the first failure (golden).
- **The real run** on the test app record is recorded in the pull request, without IDs (section 8).

**`init` as built.** `wincode init` writes `wincode.yaml` in the root of the Flutter project (the nearest folder at or above the current one with `pubspec.yaml` and `ios`), or at `--config`. It reads nothing but `ios/Runner.xcodeproj`, the files that project names, `ios/Runner`, and the `.mobileprovision` files directly in a folder the user names. It does not search the disk, read a credential store, or use the network.
- **Detection.** The bundle ID is the `PRODUCT_BUNDLE_IDENTIFIER` of Release, resolved as Xcode layers the settings (`wincode_core`'s reader); Debug and Profile must agree with it. `--flavor <name>` reads only `Release-<name>`, the App Store build: `Debug-<name>` and `Profile-<name>` are not read, because the debug build of a flavor may have a bundle ID of its own. `--configuration <name>` reads only the configuration of exactly that name; a name that the project does not have fails and lists the names that it has (`configuration-not-found`, exit 1). With either option, the output says which configuration was read, and `--json` has it as `configuration`. Giving both was a usage error. *ADR-0014 changed this in its implementation pull request 3 (built): the two options may be combined, `--configuration` overriding the default `Release-<flavor>`, and `init` records `flavor` and `configuration` in the file.* As built, `--configuration` is an option of the command only: the schema of section 2 has no key for a build configuration, and the file records what was read from it, not where. When the project has configurations other than Debug, Profile and Release and neither option is given, `init` prints a WARN that lists them and suggests `--configuration` (and lists it in `warnings` of `--json`). The team ID comes from the chosen profile and from `DEVELOPMENT_TEAM`; two different ones are asked. The entitlements file is the one the project names, else the only `.entitlements` file of `ios/Runner`. A profile is offered only if it is an App Store profile, has not expired, and is for the bundle ID.
- **Variables.** A `$(NAME)` or `${NAME}` in `PRODUCT_BUNDLE_IDENTIFIER`, `DEVELOPMENT_TEAM` or `CODE_SIGN_ENTITLEMENTS` is resolved without running anything: from the build settings of the configuration (project and target), from the xcconfig files it references with their `#include` and `#include?` chains (at most 16 deep; a file that includes itself fails at once and is named), and from the values of those, nested. A variable that nothing defines, or that refers to itself, is listed (`<SETTING> of <configuration> needs $(NAME), which no build setting or xcconfig file of <configuration> defines`) and the value is asked, never guessed. A run that cannot ask fails with `not detected ($(NAME) is not defined in <configuration> or its xcconfig files); pass --<option>` (`init-input-missing`, exit 64), also for the optional entitlements file, which would otherwise be left out. A value that is detected but is not a bundle ID, or a bundle ID that differs between Release, Debug and Profile in the default read, is asked too.
- **Asking.** At a terminal, each value is shown with what was found, and Enter accepts it; the file is shown and confirmed before it is written. With `--yes`, with `--json`, in CI (`CI` set), or when standard input is not a terminal, nothing is asked: every field comes from an option, or from what was found with `--yes`. A value that cannot be settled stops the run (`init-input-missing`, exit 64), and each is listed with where it was found: `detected <value> in <source>; confirm with --yes or pass --<option>`, `detected several (<value> in <source>, ...); pass --<option>`, or `not detected; pass --<option>`. The values pass through the redactor, so `--redact` and CI show `<bundle ID>` and `<team ID>`. Options: `--bundle-id`, `--team-id`, `--profile`, `--profile-dir`, `--entitlements`, `--workflow-ref`, `--output`, `--flavor`, `--configuration`, `--yes`, `--force`, `--workflow`.
- **Safety.** An existing file is not replaced without `--force`; `init` prints a diff of what it would change (`config-exists`, exit 1). A profile is checked with `requireOutsideGit` before it is read, so one in an unignored git working tree is refused with the move-it message (exit 78); a profile folder inside the project gets a suggested `.gitignore` line, and `.gitignore` is never edited. `--dry-run` prints the file and writes nothing. IDs are registered with the redactor as soon as they are found, so `--redact` and CI hide them in all output, and the file keeps the real values. The file holds no key and no key folder: it has no field for one, and `WINCODE_ASC_KEY_DIR` is never read by `init`.
- **The reference workflow.** `--workflow` writes `.github/workflows/wincode-ios.yml` and refuses to replace it, with or without `--force`. The text is embedded in the program: `lib/src/workflow_template.g.dart` is generated from the readable source `packages/wincode_cli/templates/wincode-ios.yml` by `dart run tool/embed_template.dart`, and a test fails when the constant and the file differ by a byte, so a compiled `wincode` needs no checkout. The Windows CI job compiles `wincode` with `dart compile exe` and runs `init --workflow`, first with `--dry-run` and then for real, in a generated project away from the source tree, and compares the file with the template. `init` does not write the `workflow:` key unless `--workflow-ref` gives it: the repository and branch are not known without asking GitHub.
- **After it,** `init` prints the commands to run: `wincode preflight --dry-run` and `wincode preflight`, with `--config` when the file is not `wincode.yaml` in the current folder.

**Phase 3: `sign`.** Accepted when:
- each check of section 4 has a test, with a throwaway CA, identity and profile, and a fake zsign;
- the certificate is checked before signing: the expiry of the local certificate, and its status in App Store Connect through a read-only `GET /v1/certificates`, matched by serial number. A revoked or expired certificate, or one that App Store Connect does not list, fails before zsign runs (preflight does not request certificates, so this is the first use of that request), with a test for each case against the fake server;
- the read-back is in Dart (the entitlements blob of the code signature that `LC_CODE_SIGNATURE` points to), with its format notes in `docs/formats/` first;
- the setup script builds the pinned zsign and records its SHA-256, and `wincode sign` refuses another one unless `ZSIGN` names it;
- `wincode doctor` reports a missing WSL2 distribution and a changed or missing zsign with the messages of section 4 (a fake `wsl.exe` in the tests), and every path reaches WSL2 through `wslpath -u`;
- a test fails if a process is started with `-p`, and no output holds a password; a `.p12` or an encrypted key is refused;
- the open risk of the working key in section 4 is decided with the maintainer, and the decision is recorded here;
- with the same unsigned bundle and throwaway identity, `wincode sign` and `sign.py` sign the same entitlements into each binary, and both read-backs pass;
- a hybrid-lane IPA signed by `wincode sign` is uploaded, with the maintainer's yes, and processed as valid.

**Phase 3a as built: `sign` with an unencrypted PEM key, and `doctor --sign`.** What was built, and where it departs from the sections above:
- **Order of `wincode sign`,** each step a check of the report. Steps 1 to 5 read local files and all run, so one report lists every local problem. Step 6 and later run only when none of them failed:
  1. `input`: the unsigned IPA (`<output>/unsigned.ipa` by default) holds one `Payload/<name>.app` of `bundle_id`, nothing outside `Payload/`, and no app extension (`PlugIns/*.appex`) or nested app (a watch app). Those need their own profiles and entitlements, so they fail with `extensions-unsupported` instead of being signed with the app's profile.
  2. `local-profile`: preflight's check of the profile in `wincode.yaml`, after `requireOutsideGit`.
  3. `dist-key`: the key comes only from the app's credentials reference, or `WINCODE_DIST_KEY` for a flat file without one (ADR-0014's `resolveDistKey`), and must be an unencrypted RSA key in PEM, PKCS #8 or PKCS #1. An encrypted PEM key or a `.p12` fails with `key-encrypted` (78), another kind of key with `key-not-rsa` (1). Its path is a secret in every output. A path on the WSL2 disk (`\\wsl.localhost\...` or `\\wsl$\...`, in the variable or the keys root) fails at once with `dist-key-unreachable` (78): ADR-0014 keeps keys on the Windows side. The message names where the key belongs, `<keys root>\<reference>\dist.key` or a Windows-drive file for `WINCODE_DIST_KEY`.
  4. `certificate`: the certificate of the profile's `DeveloperCertificates` whose RSA public key is the key's (`certificate-not-in-profile` when none is), with a common name of "Apple Distribution:" or "iPhone Distribution:", the team ID as its organizational unit, and not expired. Only the part of the name before the colon is printed.
  5. `entitlements`: sign.py's `minimal_entitlements`, ported line for line and tested with its self-test cases. It takes the app's `entitlements` file and sets `application-identifier`, `com.apple.developer.team-identifier`, `get-task-allow` false and `keychain-access-groups` from the profile's team. Each key must be allowed by the profile (`entitlement-not-allowed`, one failure per key). `--verbose` prints the final entitlements through the redactor.
  6. `certificate-asc`: `GET /v1/certificates` (fields `serialNumber`, `certificateType`, `expirationDate`), matched by serial number in upper-case hexadecimal without leading zeros. Not listed, not `DISTRIBUTION` or `IOS_DISTRIBUTION`, or expired fail before zsign. `--offline` skips only this request, with a WARN; `--dry-run` sends nothing and prints the zsign command with placeholders.
  7. `zsign`: the pinned binary (below). In a folder `.wincode-sign-<random>` in the output folder, `sign` writes the certificate (PEM) and the entitlements, translates every path with `wslpath -u` in the distribution, checks that the key is readable there (`test -r`; `dist-key-unreachable`, 78), and runs `wsl.exe [-d <distribution>] --cd <folder> --exec <zsign> -k <key> -c <certificate> -m <profile> -e <entitlements> -t <folder>/zsign -z 9 -o <folder>/signed.ipa <unsigned IPA>`. There is no `-p`, and no shell. The IPA goes to zsign as it is (a zip input makes zsign sign everything again), where `sign.py` passed a copy of the `.app`. zsign is stopped after 20 minutes (`zsign-timeout`) or when its folder passes 1 GB (`zsign-too-big`). A non-zero exit or no output is `zsign-failed`, with zsign's last line as the why.
  8. `code-signature`: the read-back of [`docs/formats/code-signature-verification.md`](../formats/code-signature-verification.md), in `wincode_core` (`checkSignedIpa`). Every Mach-O file, and each slice of a fat file, carries a signature. Its code directories name the bundle's identifier (or the file name, for a loose library) and `team_id`, and hash every page and the special slots: Info.plist, requirements, `CodeResources`, XML and DER entitlements. The app's executable carries exactly the entitlements of step 5, as XML and as DER, and every other file an empty set (a missing DER blob is a WARN). Each `_CodeSignature/CodeResources` seals exactly its bundle's files with their SHA-1 and SHA-256. The CMS signature is detached and signed by the chosen certificate, its message digest and `cdhashes` match the code directories, and its RSA signature verifies. `embedded.mobileprovision` is the configured profile, byte for byte.
  9. Preflight's local checks on the signed IPA (`ipa`, `signature`, `profile-link`). Only when all of them pass is the IPA renamed to `<output>/signed.ipa`. The temporary folder is deleted in a `finally`, whatever happened: a failure, a timeout or a stopped zsign leave no file behind, and an earlier `signed.ipa` stays as it was.
- **`--verify-only [<signed .ipa>]`** runs steps 2, 4 to 6, 8 and 9 on a signed IPA (`<output>/signed.ipa` by default). It reads no private key: the certificate is the one that the CMS signature of the app's executable names as its signer, and it must be one of the profile's `DeveloperCertificates`, byte for byte (`certificate-not-in-profile`). Step 6 asks App Store Connect about it unless `--offline` or `--dry-run` is given. It needs no WSL2.
- **Selection:** `sign` takes `--app` like every command, refuses `--all` (it writes), and uses the app's output folder. Under `--redact` or `CI`, the IDs, the names and the paths taken from the config are placeholders, the unsigned IPA is `<unsigned IPA>`, and the WSL2 forms of the paths get the placeholders of their Windows forms.
- **The pinned zsign:**
  - **Pin:** `xtool-org/zsign` 1.9.0, commit `f6158be9e62a5ce2a53d72b1a6d880880da956c8`. GitHub's archive of it has the SHA-256 `423ebe2f4dd3380367461c03e6de3b9e9f31adcbe9a2f0237493c8f0bf9b7c5d`. A test checks that `third_party/xtool/Package.resolved` pins the same commit and that the CI job builds it.
  - **Licences:** MIT ("Copyright (c) 2026 zhlynn", its `LICENSE`). It builds its own copies of zlib and minizip (zlib licence) and links OpenSSL 3 (Apache-2.0).
  - **Built by the user:** `wincode doctor --sign` prints the commands (install the build tools if missing, download the archive, check its SHA-256 with `sha256sum -c`, unpack, `make`, with `CXX=clang++ CC=clang` where there is no g++). The user runs them in the distribution. winCode runs none of them, never runs `sudo`, and installs nothing. The binary lands at `~/.wincode/zsign/zsign-<commit>/bin/zsign`.
  - **The record:** the first `doctor --sign` that finds the binary at that path, printing `version: 1.9.0`, writes its SHA-256 to `%LOCALAPPDATA%\wincode\zsign.json` (outside every repository), per distribution. `sign` refuses to run while no hash is recorded (`zsign-unverified`) or when the binary's hash differs (`zsign-changed`). The next step is to delete the record and run `doctor --sign` again after a deliberate rebuild.
  - **A CI-built static binary was considered,** and is not built. It would spare the user a toolchain, but winCode would then distribute a signing tool, with its provenance, notices and Windows Defender's view of it (section 4). It also would not remove WSL2, which F1 is for.
- **`wincode doctor --sign`,** per app, each failure with its next step:
  - `wsl.exe -l -v` lists the distribution, which runs on WSL 2 (`wsl-missing`, `wsl-distro-missing`, `wsl-version`). wsl.exe writes that list in UTF-16.
  - The distribution starts and has a home folder (`wsl-unreachable`).
  - zsign is built and prints its version (`zsign-missing`, with the build commands as INFO).
  - Its SHA-256 is recorded and unchanged (recorded now when none is).
  - The app's distribution key is found, exists, and is readable from WSL2 through `wslpath` (`dist-key-missing`, `dist-key-unreachable`).
  - `doctor --sign --dry-run` is refused, since `doctor --sign` records the hash.
- **Tests,** with no network and no WSL2:
  - A fake `wsl.exe` answers `-l -v`, `printenv HOME`, `wslpath -u`, `test -r`, `sha256sum` and `zsign -v`, and a fake zsign process behind `ZsignRunner` signs, fails, hangs, writes garbage or grows. After every failure, no temporary file and no `signed.ipa` are left, and a hanging or growing zsign is killed.
  - Every path that zsign gets is a translated one, the key's among them. `-p` is never passed, and the key and its path appear in no output.
  - Keys, certificates and profiles are throwaway ones that the tests make: `wincode_core`'s `testing.dart` has a small RSA key generator, self-made X.509 certificates, and a test signer that lays signatures out as zsign does. The read-back is tested against it, positive and negative.
  - Two apps of one file sign with the keys of their own credentials, and a flat file signs with `WINCODE_DIST_KEY`.
- **Integration:** a CI job on Ubuntu builds the pinned zsign with the printed commands. It makes a throwaway CA, a distribution certificate and a CMS-signed profile with openssl, generates a minimal app (`tool/zsign_fixture.dart`: two hand-made Mach-O files, a framework, a resource), signs it with zsign, and runs `wincode sign --verify-only` on the result. It then changes a file in the IPA and expects the check to fail.
  - zsign gets the certificate there as a `.p12` with the CA, without a password and so without `-p`. Given a PEM certificate, zsign looks its issuer up among Apple's own intermediates, which a throwaway CA is not. So the flags of a real run, a PEM key with `-c <certificate>`, are covered only by the acceptance runs on the test app, not by CI.
  - `wincode sign` itself starts zsign through `wsl.exe`, which a Linux runner has not, so the job does not run it.
- **Verified by hand, offline, on the test app:**
  - The pinned zsign builds in WSL2 with the printed commands, with the Swift toolchain's clang.
  - The IPA that `sign.py` signed for build 13, installed from TestFlight, passes `wincode sign --verify-only` and preflight's local checks. So does a new signing of the same unsigned input by `sign.py`.

**Phase 3a.1: `doctor --sign --build-zsign`.** Not built. Phase 3a trusts the first zsign that `doctor --sign` finds at the pinned path, so it cannot tell a binary built from the pinned source from any other zsign 1.9.0 placed there. 3a.1 makes the provenance known:
- `wincode doctor --sign --build-zsign` downloads the pinned source archive, checks its SHA-256 before unpacking it, and builds it inside WSL2 into a folder that winCode owns (`~/.wincode/zsign/zsign-<commit>`), as the user and without `sudo`. A missing build tool stops it with the install command to run by hand; it installs nothing.
- It then records the hash of the binary it built, replacing a record that `doctor --sign` made from a binary found in place. `sign` keeps refusing a binary whose hash differs.

**Phase 3b: encrypted keys.** Not built. It is the mitigation of section 4's open risk:
- `wincode sign` accepts an encrypted PKCS #8 key (`ENCRYPTED PRIVATE KEY`) and asks for its password on the terminal, never as an argument or a variable. It refuses to ask when standard input is not a terminal.
- In the distribution, it runs `openssl pkey -passin stdin -in <encrypted key, translated> -out <file>`, with the password on standard input. The file is new, of mode 0600, in a folder of mode 0700 that it creates in a tmpfs (`$XDG_RUNTIME_DIR`, else `/dev/shm`). zsign gets that file's path with `-k`.
- The file and its folder are deleted in a `finally`: after zsign ends, fails, times out or is killed, and when `openssl` fails (a wrong password). A test proves the deletion on each of those failures with the fake `wsl.exe` and zsign. A real run checks that nothing is left in the tmpfs afterwards.
- This is the only place a key may appear inside WSL2. The password lives only in winCode's memory, and is never logged.

**Phase 4: `upload` and `status`.** Accepted when:
- the fake-server cases of section 8 pass: nothing is retried, the parts rebuild the IPA byte for byte, the token never goes to a part's URL, and no hidden value is printed;
- `wincode upload --dry-run` prints the same requests as `asc_upload.py --dry-run` (golden);
- `upload` runs `preflight` first and stops when it fails;
- `upload` runs `preflight` in strict mode, in which an unsigned IPA fails: no `embedded.mobileprovision`, a profile that is not the one in `wincode.yaml`, or an executable without the signed `application-identifier` stops the upload with exit 1 and the next step "run wincode sign". Standalone `wincode preflight` reports an unsigned IPA as INFO. A test covers each of the two modes;
- one real upload, with the maintainer's yes, is processed as valid, and its output shows the same steps as spike C's run; `wincode status` then shows it.

**Phase 5: `build`.** Accepted when:
- against a fake `gh`, the run is found by its URL and by its title, waited for and downloaded, and each failure gives its message: `gh` missing (69), not logged in (77), a failed run (1), a missing artifact (1), a wrong bundle ID (1);
- the reference workflow passes actionlint, and `wincode init` writes it byte for byte (golden);
- on a test app's repository, `wincode build`, `wincode sign` and `wincode upload` in a row end with a build processed as valid, using macOS minutes and an upload that the maintainer says yes to.

**Follow-ups,** not phases, and not started:
- **F1. A native Windows zsign build,** after phase 4 is accepted, so that signing and uploading work through WSL2 first. It follows the route in section 4 (a CI build against a pinned OpenSSL, a published hash, equal code directory hashes with the WSL2 build, one VALID upload). It is done when `wincode sign` can use it without WSL2, and the WSL2 checks of `doctor` become optional. The interim decision of section 4 ends here.

## Consequences

- **Windows users need no Python.** `build` needs `gh` and a GitHub repository. `sign` needs WSL2 with the pinned zsign, so a user of the hybrid lane installs WSL2 only to sign, until a native zsign or a Dart signer replaces it.
- **The spike scripts keep working** until each phase replaces them, and then stay as spike C's record.
- **`doctor` changed in the skeleton,** which matters to a script that calls it:
  - a usage error (a missing or unknown option, a positional argument) goes to stderr with the usage and exits 64, with nothing on stdout (unless `--json` asks for its object);
  - `--sdk` naming a folder without `SDKSettings.json` exits 69 (`sdk-missing`) instead of 1;
  - its other errors use the three-line form on stderr, and with `--json` stdout carries one object.

  The checks and the exit codes 0 (pass) and 1 (a check failed, or a file cannot be read) are as before.
- **ADR-0008's `wincode ship --lane mac`** becomes `build`, `sign` and `upload`; a `ship` that chains them is still possible later.
- **ADR-0009's Windows Credential Manager waits:** the variables of section 2 hold until a decision moves the keys.
- **Where zsign runs is interim.** WSL2 holds until follow-up F1; until then a hybrid-lane user needs WSL2 to sign, and `wincode doctor` says what is missing.
- **IDs are visible by default, hidden in CI.** A person who runs `wincode` sees the bundle ID and team ID; a CI log does not, and nobody pastes them into an issue by accident (section 7).
- **To revisit:** the decision on the unencrypted working key (section 4); where zsign runs once F1 is done, or if a Dart signer is wanted; the credential store; the build-number rule, if Apple's per-version rule is confirmed on a test app.

## Alternatives considered

- **The REST API instead of `gh`:** no extra tool, but winCode would hold, store and redact a GitHub token. `gh` is one install and keeps the login itself.
- **Keeping Python behind the CLI (A), or porting everything at once (B):** section 5.
- **A Dart signer, or a native Windows zsign now:** section 4.
- **JSON or TOML for the settings:** Flutter projects already use YAML (`pubspec.yaml`), and YAML takes comments, which `init` uses to explain each key.
- **Secrets in `wincode.yaml`, even encrypted:** the file goes with the project, and an encrypted secret still needs a key from somewhere else, which is what the variables are.
- **An exit code per failure:** too many to remember; the `id` in `--json` tells failures apart.
- **A question before `upload`:** running `upload` is the decision, `--dry-run` shows what it would send, and the preflight runs first. A prompt would also stop CI.

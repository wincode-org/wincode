# wincode_cli

The `wincode` command. Its design is [ADR-0013](../../docs/adr/0013-wincode-cli-build-sign-upload.md).

Status: `doctor`, `preflight`, `init` and `sign` work, and `upload` is built and tested against a fake App Store Connect, not yet exercised against the real one from `wincode`. `preflight` and `doctor` read an app's App Store Connect key through its `credentials` reference (ADR-0014; layout below), and `sign` its distribution key. `sign` signs with an unencrypted PEM key only (ADR-0013, phase 3a); encrypted keys come in phase 3b. `upload` needs no WSL2 and runs on Linux too. The other commands are registered; each prints `not implemented yet, see ADR-0013` and exits with 64 until the phase of ADR-0013 that implements it. `wincode.yaml` may describe several apps ([ADR-0014](../../docs/adr/0014-one-project-many-apps.md)): `--app <name>` chooses the app of `preflight`, `doctor` and `init`, `--all` runs `preflight` and `doctor` for every app, and `init --app` adds an app to a file of apps, or moves a flat file under `apps:` (below).

```
dart run wincode_cli:wincode <command> [arguments]
```

| Command | What it will do | Phase |
| --- | --- | --- |
| `init` | Write `wincode.yaml` for the Flutter project in this folder | works |
| `preflight [<signed .ipa>]` | Check the signed IPA and App Store Connect before an upload. Read-only | works |
| `sign [<unsigned .ipa>]` | Sign the IPA for the App Store with zsign in WSL2, and check every signature | works (3a) |
| `upload [<signed .ipa>]` | Upload the signed IPA to App Store Connect and wait for its processing | built (4), not yet run against Apple |
| `status` | Show the state of the app's latest uploads in App Store Connect. Read-only | 4 |
| `build` | Build the unsigned IPA on the app's macOS runner (GitHub Actions) and download it | 5 |
| `doctor` | Check the setup (with `--sign`, what `sign` needs), or a Mach-O binary against the SDK or a reference build | works |

## Global options

They go before or after the command.

- `--config <file>`: the app's settings, `wincode.yaml` by default (below).
- `--app <name>` and `--all`: which app of a `wincode.yaml` with an `apps:` map the command works on (below).
- `--json`: one JSON object on stdout when the command ends, with `command`, `app` (the name, or null for a flat file), `ok`, `exitCode`, the results, and on a failure `error` with `id`, `what`, `why` and `next`. Messages go to stderr. With `--all` it is one document (below).
- `--redact`: hide the bundle ID and team ID, and the names of apps, credentials references, flavors and the paths of the settings, in everything printed. It is always on when the `CI` environment variable is set (not empty, `0` or `false`). Commands register the IDs they learn with the redactor.
- `--verbose`: also print each step, external command and HTTP request, with secrets redacted.
- `--dry-run`: send, write and run nothing, and print what would be done.

`doctor`, `preflight`, `init` and the error output use `--json`. `--config` and `--dry-run` are used by `preflight` and `init`, and the HTTP lines of `--verbose` by `preflight`; otherwise `--verbose` adds only the stack trace of an internal error.

## Choosing the app (ADR-0014, section 3)

- **One app, or a flat file:** no `--app` is needed. With several apps and no `--app`, the command stops with exit 64 (`app-required`) and lists the names. A name that is not in the file is `app-unknown` (64), and the file's names are in `apps` of the `--json` error. A flat file has no names, so `--app` is refused there (`app-flat-file`, 64), except by `init`. There is no default app.
- **`--all`** is for the commands that only read: `preflight` (each app's `signed.ipa`, so no IPA argument) and `doctor` without options, and `status` once it is built. The apps run in file order and a failure does not stop the next one. Each prints under `== <app> ==`, then comes a table and a last line:

  ```
  app    result  first failure        exit
  app-1  PASS                         0
  app-2  FAIL    credentials-missing  78
  app-3  PASS                         0
  wincode doctor --all: 1 of 3 apps failed; exit 78, the first failure in wincode.yaml (app-2).
  ```

  The exit code is that of the first failing app in file order, else 0. With `--json` it is one document: `command`, `all`, `ok`, `exitCode`, `apps` (each app's object as the command alone prints it, without `command`) and `error` (the first failing app's, with `app`).
- **`--all` is refused** by `sign`, `upload`, `build` and `init` (`all-not-allowed`, 64): each writes, and a loop over apps would leave some done and some not, with nothing that records which. Run them once per app with `--app`. `--app` and `--all` together are a usage error, and the Mach-O checks of `doctor` (`--binary`) read no settings, so they refuse both.
- **Names are hidden** by `--redact` and in CI: `app-1`, `app-2` in file order, `credentials-1`, and so on, in the report, the table, the error messages and `--json`.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Done |
| 1 | Failed: a check found a problem, an input is wrong, or Apple or GitHub refused the work |
| 64 | Usage error, or not implemented yet |
| 65 | `upload`: Apple took the IPA and then failed its processing |
| 69 | A tool, the SDK or the network is missing |
| 70 | A bug in winCode |
| 75 | `upload`: Apple had not finished its processing within `--timeout` |
| 77 | Apple or GitHub refused the credentials |
| 78 | `wincode.yaml` or an environment variable is wrong |

Every failure prints what happened, why, and the next step:

```
wincode doctor: <what happened>
  why: <why>
  next: <the next step>
```

## wincode.yaml

One file per app, with no secrets. Paths are relative to the file.

```yaml
bundle_id: com.example.app
team_id: TEAM000000
profile: ../signing/App_Store.mobileprovision
entitlements: ios/Runner/Runner.entitlements
workflow: example-org/example-app/.github/workflows/wincode-ios.yml@main
output: build/wincode
```

`bundle_id` and `team_id` are required, and `output` defaults to `build/wincode`. Every value must be text. An unknown key is refused, and so is a key whose name looks like a secret; messages name the key, never its value. `loadConfig` reads and checks the file; `preflight` reads it, and `init` writes it and checks what it writes with `parseConfig`.

A flat file may also hold `flavor`, `configuration` (which defaults to `Release-<flavor>`, or `Release`), `workflow_inputs` and `credentials`; everything else about a flat file is as it was.

### Several apps

A file with an `apps:` map describes one app per entry, and `defaults:` holds what they share (ADR-0014, section 1):

```yaml
defaults:
  team_id: TEAM000001
  credentials: team-one
apps:
  alpha:
    bundle_id: com.example.alpha
    flavor: alpha
  beta:
    bundle_id: com.example.beta
    flavor: beta
    output: out/beta
```

- A file with `apps` holds only `apps` and `defaults` at the top level; the flat file stays valid and is loaded as one app without a name.
- `defaults` may hold `team_id`, `entitlements`, `workflow`, `workflow_inputs` and `credentials`. An app's own value replaces a default whole. `bundle_id`, `flavor`, `configuration`, `profile` and `output` are per app.
- Every app needs `bundle_id`, `team_id` and `credentials` (the name of a credentials reference; no command reads one yet). `output` defaults to `build/wincode/<app>`.
- An app name and a credentials reference have 3 to 32 lower-case letters, digits and hyphens, start with a letter and end with a letter or digit, and are not an ordinary word (`build`, `key`, `app`, `release`, ... `reservedNames` in `lib/src/config.dart` has the list), a Windows device name or the shape of a placeholder such as `app-1`.
- Bundle IDs are unique (ignoring case), output folders are unique, and one credentials reference serves one team. Messages name the line and, for a name that passed its rules, the app; a refused name is never printed.
- `workflow_inputs` names are plain, not `request_id`, `flavor` or `build_number`, and not secret-looking; values are at most 64 plain characters.
- `loadSettings` and `parseSettings` return every app in file order (`WincodeSettings`). `loadConfig` returns the one app that existing commands work on, and refuses a file of several with exit 64 (`not-implemented`).
- With a `Redactor`, the loader registers the names, bundle IDs, team IDs, credentials references, flavors, configurations and the `profile`, `entitlements` and `output` paths as soon as each has passed its checks, so that `--redact` and CI print `app-1`, `<bundle ID 1>`, `credentials-1`, `Release-app-1`, `<profile of app-1>` and `<output of app-1>/signed.ipa` even in an error message (ADR-0014, section 4). `preflight` passes its redactor to the loader.

Secrets come only from environment variables, which name files outside the project: `WINCODE_ASC_KEY_DIR` (the App Store Connect key folder) and `WINCODE_DIST_KEY` (the distribution key, a file on a Windows drive that zsign reads in place). `preflight` reads `WINCODE_ASC_KEY_DIR` and `sign` both (ADR-0013, section 2). A key or profile file inside a git working tree is refused unless git ignores it: `requireOutsideGit` does the check, and `preflight` calls it on each file of the key folder that it reads and on the profile, `init` on the profile, and `sign` on the distribution key and the profile, before reading them.

### The keys folder (ADR-0014, section 2)

An app that names `credentials: <reference>` has its keys in a folder of that name under the keys root, on the Windows side (nothing is written inside WSL2, and `preflight` never starts `wsl.exe`). Names only:

```
%USERPROFILE%\.wincode\keys\
  <reference>\
    AuthKey_<Key ID>.p8    the App Store Connect API key, as App Store Connect delivered it (exactly one)
    issuer-id              one line: the Issuer ID
    dist.key               the distribution private key (unencrypted PEM); read in place by `sign`
```

- **The root** is `WINCODE_KEYS_DIR` when it is set, else `.wincode/keys` in the user profile folder (`USERPROFILE`, or `HOME` where there is none).
- **The Key ID** is taken from the name `AuthKey_<Key ID>.p8` and the Issuer ID from `issuer-id`: neither is in `wincode.yaml` or in a variable.
- **Per reference**, for CI and for keys kept elsewhere: `WINCODE_ASC_KEY_DIR_<REF>` names a folder with the `.p8` and `issuer-id`, and `WINCODE_DIST_KEY_<REF>` a file for `dist.key`; `<REF>` is the reference in capitals with `-` as `_` (`team-one` gives `TEAM_ONE`). Each replaces its own half only. Apps of one team name one reference and share its folder.
- **A flat file without `credentials`** keeps `WINCODE_ASC_KEY_DIR` and `WINCODE_DIST_KEY`, with the single-file git rule above. An app with `credentials` never reads those two, and a missing folder says so.
- **The keys root, and every folder that a variable of a reference names, is refused inside any git working tree, even when git ignores it**, and in OneDrive. A repository made inside the root is found too. If git cannot answer, the folder is refused. Messages name the variable or the reference, never a path.


## init

```
dart run wincode_cli:wincode init [--yes] [--force] [--dry-run] [--flavor <name>] [--configuration <name>]
    [--app <name>] [--credentials <name>] [--bundle-id <id>] [--team-id <id>] [--profile <file> | --profile-dir <folder>]
    [--entitlements <file>] [--workflow-ref <ref>] [--output <folder>] [--workflow]
```

Writes `wincode.yaml` in the root of the Flutter project: the nearest folder at or above the current one with `pubspec.yaml` and `ios`. It reads `ios/Runner.xcodeproj` and `ios/Runner`, and the `.mobileprovision` files directly in the folder that `--profile-dir` (or your answer) names. It searches nothing else, reads no credential store, and uses no network. The file has no field for a key, and `WINCODE_ASC_KEY_DIR` is not read.

| Value | Where it comes from |
| --- | --- |
| `bundle_id` | The `PRODUCT_BUNDLE_IDENTIFIER` of Release, if Debug and Profile agree. `--flavor <name>` reads only `Release-<name>`, the App Store build, and does not read Debug-`<name>` or Profile-`<name>`, which may differ. `--configuration <name>` reads exactly that configuration. A variable with no value, or a bundle ID that differs between configurations in the default read, is listed and asked, never guessed |
| `team_id` | The profile, and `DEVELOPMENT_TEAM` of the Xcode project; two different ones are asked. A variable in it is resolved like the others (below) |
| `profile` | A `.mobileprovision` in the folder that you name that is an App Store profile for the bundle ID and has not expired. It must lie outside git working trees, or git must ignore it |
| `entitlements` | The file the Xcode project names, else the only `.entitlements` file of `ios/Runner` |
| `workflow`, `output` | `--workflow-ref` (left as a comment without it), and `--output` (default `build/wincode`) |

At a terminal, `init` shows each value with what it found (Enter accepts it, `-` leaves an optional one out) and asks before it writes. With `--yes`, with `--json`, with `CI` set, or when standard input is not a terminal, it asks nothing: give every field as an option, or `--yes` to accept what it found. Otherwise it fails with exit 64 (`init-input-missing`) and says, for each value that is not settled, `detected <value> in <source>; confirm with --yes or pass --<option>`, `detected several (...); pass --<option>`, or `not detected; pass --<option>`.

If the project has build configurations other than Debug, Profile and Release (for example one per flavor) and you gave neither `--flavor` nor `--configuration`, `init` prints a `WARN` that lists them and says that it read Release. `--configuration <name>` has no counterpart in `wincode.yaml`. A name that the project does not have fails (`configuration-not-found`, exit 1) and lists the names it has.

With `--flavor` or `--configuration`, `init` prints `Read the build configuration <name> of ios/Runner.xcodeproj.` (and `--json` has `"configuration"`). `--flavor` and `--configuration` may be combined: `--flavor` is recorded (`flavor:`) and names the default configuration, `Release-<flavor>`, and `--configuration` overrides it and is recorded (`configuration:`) only when it is another name. `--credentials <name>` records the credentials reference. A `$(NAME)` or `${NAME}` in the bundle ID, the team ID or the entitlements file is resolved without running anything: from the build settings of that configuration, from the xcconfig files it references and their `#include` and `#include?` chains (16 deep at most; a file that includes itself fails at once and is named), and from nested variables. A variable that nothing defines is listed (`PRODUCT_BUNDLE_IDENTIFIER of Release-alpha needs $(APP_ID), which no build setting or xcconfig file of Release-alpha defines`) and asked, never guessed; a run that cannot ask fails with `not detected ($(APP_ID) is not defined in Release-alpha or its xcconfig files); pass --bundle-id`.

- **`--app <name>`** (ADR-0014, section 5) works on a file of apps. Without a `wincode.yaml` it starts one with that app; with one it adds the app, or updates its entry, after showing the changes with `-` and `+` and asking (`--yes` where it cannot ask; without it, `init-input-missing`, 64, and nothing is written). A value that the entry already has is replaced only with `--force` (`app-exists`, exit 1, otherwise). A value that equals the one the entry inherits from `defaults` is left out, `defaults` is never touched, and `credentials` is required (asked, or `--credentials`). The file is edited in place (`yaml_edit`): comments, blank lines and key order stay, and only the entry changes. Without `--app`, a file of apps is `app-required`, and `--app` on a flat file moves it under `apps:` (below). `--all` is refused.
- **An existing `wincode.yaml` is kept** (`config-exists`, exit 1) and the lines that would change are shown with `-` and `+`; `--force` replaces it.
- **A profile in a git working tree that git does not ignore is refused** (`key-in-git-tree`, exit 78) before it is read. A profile inside the project gets a suggested `.gitignore` line; `init` never edits `.gitignore`.
- **`--dry-run`** prints the file and writes nothing. **`--redact`** and `CI` hide the bundle ID and team ID in everything printed; the file keeps the real values.
- **`--workflow`** writes `.github/workflows/wincode-ios.yml` and never replaces that file. The text is built into `wincode`, so a compiled `wincode` needs no checkout. `templates/wincode-ios.yml` is the readable source: after changing it, run `dart run tool/embed_template.dart` in `packages/wincode_cli`, and a test fails if the two differ.
- It ends with the commands to run next: `wincode preflight --dry-run`, then `wincode preflight`.
- With `--json`, stdout gets `{"command": "init", "app": null, "ok": true, "exitCode": 0, "dryRun": false, "written": true, "config": {...}}`, with `"warnings"` (a list) when `init` warned, and `"workflow": "copied"` or `"would-copy"` when `--workflow` was given; the report goes to stderr.

### Migrating to several apps (ADR-0014, section 5)

To move a flat `wincode.yaml` under `apps:`, run `wincode init --app <name> --credentials <reference>` (with `--flavor` when the app has one) in the project. `init` reads the Xcode project for the app and checks that the file describes it (its bundle ID is the file's: else `config-is-another-app`, and the message says to name that app first). It then shows the whole change with `-` and `+`, and asks (`--yes` where it cannot ask; `--force` is not a yes). The file's values stay as they are: `init` adds `flavor`, `configuration` when it is not `Release-<flavor>`, `credentials`, and `output: build/wincode` when the file had no `output`. The original is kept next to it as `wincode.yaml.bak`; an earlier backup stops the run unless `--force`. Because the shape changes, the new file is written fresh, and the comments are in the backup. Options that set a value (`--team-id`, `--profile`, ...) are refused during the move; use them on the next run. Then add the other apps with `wincode init --app <name>`, which edits the file in place: its comments, blank lines and key order stay, and only the entry changes. After every write `init` loads the file again and puts the old one back if it does not load.

## preflight

```
dart run wincode_cli:wincode preflight [<signed .ipa>]
```

Read-only checks before an upload. In App Store Connect it sends GET requests only; it never creates, changes or uploads anything. Without an argument it checks `signed.ipa` in the `output` folder of `wincode.yaml`.

The API key of an app with `credentials` comes from its folder under the keys root (see "The keys folder" above). For a flat file without `credentials` it comes from the folder that `WINCODE_ASC_KEY_DIR` names, outside every project and outside OneDrive: `AuthKey_<Key ID>.p8`, as App Store Connect delivered it, and a file `issuer-id` with the Issuer ID on one line. The token, the Key ID, the Issuer ID and the folder are never printed.

The checks, in the order of the report:

| Check | What it checks |
| --- | --- |
| `key-location` | The key folder is set and outside OneDrive; its `.p8` and `issuer-id`, and the profile, lie outside git working trees unless git ignores them. A file that fails is not read |
| `api-key` | App Store Connect accepts the key: the first request, as in the spike's script |
| `app-record` | An app record has the bundle ID of `wincode.yaml` |
| `builds` | INFO: how many builds the app has, and the highest build number |
| `build-number` | The IPA's `CFBundleVersion` is higher than every existing build's, compared part by part as numbers (`1.2.10` is above `1.2.9`) |
| `store-profile` | The developer portal has the App ID, and an active App Store profile for it that has not expired |
| `local-profile` | The profile of `wincode.yaml` is an App Store profile of the team, for the bundle ID, and has not expired |
| `ipa` | The IPA is a zip archive with one app in `Payload/`, whose bundle ID is that of `wincode.yaml`, and whose version and build number are one to three numbers joined by dots |
| `signature` | When the IPA holds `embedded.mobileprovision`: that profile passes the `local-profile` checks, and the executable is signed with the `application-identifier` `<team ID>.<bundle ID>`. An IPA without it is reported (INFO), not failed: `upload` runs these checks in strict mode, where it fails (`ipa-unsigned`) |
| `profile-link` | The `UUID` of the profile agrees across App Store Connect, the profile of `wincode.yaml` and the IPA's `embedded.mobileprovision`; no UUID is printed. The file must be an active App Store profile of the App ID in App Store Connect, and a signed IPA must carry the file's profile. An unsigned IPA is an INFO |

Each check prints `PASS`, `FAIL`, `WARN` or `INFO`, and a failure or a warning prints why and the next step under it. A profile that expires within 30 days is a warning. When a request fails, the checks in App Store Connect after it are not run; the checks on this PC always are. The last line sums up, and the exit code is that of the first failure, or 0:

```
FAIL  build 13 is not higher than 13, the highest build App Store Connect has for this app
  why: Apple refuses a build number it has already seen, and a used number stays used even when its build failed.
  next: raise the build number above 13 (version: x.y.z+N in pubspec.yaml), then build and sign again.
...
wincode preflight: 1 check failed
```

| Exit | Failure ids |
| --- | --- |
| 0 | `profile-expires-soon` (a warning) |
| 1 | `profile-uuid-mismatch`, `profile-not-active`, `ipa-profile-mismatch`, `ipa-profile-unknown`, `app-record-missing`, `build-number-not-higher`, `build-number-invalid`, `version-invalid`, `bundle-id-mismatch`, `app-id-missing`, `profile-missing`, `profile-expired`, `profile-team-mismatch`, `profile-not-app-store`, `profile-unreadable`, `ipa-missing`, `ipa-unreadable`, `signature-invalid`, `asc-error` |
| 69 | `offline`, `asc-unavailable`, `git-unavailable` |
| 77 | `asc-unauthorized` (HTTP 401), `asc-forbidden` (HTTP 403) |
| 78 | `config-missing`, `config-invalid`, `asc-key-dir-missing`, `asc-key-invalid`, `key-in-onedrive`, `key-in-git-tree` |

The IPA is read within limits: at most 50,000 entries, a 32 MiB directory, 8 GiB claimed in all, and 64 MiB of one entry held in memory (the executable is read at its header and signature only). A zip64 archive, an encrypted entry, a duplicate or overlapping entry, or a name with `..` makes the IPA `ipa-unreadable` (exit 1).

Requests time out after 20 seconds. One that gets no answer or HTTP 5xx is tried twice more, after 1 and 2 seconds. `HTTPS_PROXY` and `NO_PROXY` apply.

- `--dry-run` sends nothing and prints the GET requests in the form of `asc_preflight.py --dry-run`, without its certificates request and with `uuid` added to the fields of the profiles request, with `{id of the app record}` and `{id of the App ID}` for the IDs that only Apple's answers would give. When `WINCODE_ASC_KEY_DIR` is set, it checks where the key lies and signs a token, which it does not show.
- `--verbose` adds one line per HTTP request on stderr: method, host, path, query, status or error, and time. Never the token or a header.
- `--redact`, or `CI`, hides the bundle ID and team ID of `wincode.yaml` (`<bundle ID>`, `<team ID>`), those of another app or team that the IPA or a profile names (`<other bundle ID>`, `<other team ID>`), and Apple's IDs of the app record and the App ID.

With `--json`, the report goes to stderr, and stdout gets one object. `checks` lists every finding in the order of the report, with `id`, `why` and `next` for a failure or a warning only; `error` is the first failure, and is absent when there is none:

```json
{
  "command": "preflight",
  "ok": false,
  "exitCode": 1,
  "checks": [
    {"check": "api-key", "status": "PASS", "what": "App Store Connect accepts the API key"},
    {"check": "build-number", "status": "FAIL", "id": "build-number-not-higher", "what": "...", "why": "...", "next": "..."}
  ],
  "error": {"id": "build-number-not-higher", "what": "...", "why": "...", "next": "..."}
}
```

With `--dry-run --json`, it is `{"command": "preflight", "ok": true, "exitCode": 0, "dryRun": true, "requests": ["GET https://...", ...]}`. The names of the checks, the statuses and the ids are stable; the texts are not.

## sign

```
dart run wincode_cli:wincode sign [--app <name>] [--offline] [<unsigned .ipa>]
dart run wincode_cli:wincode sign --verify-only [<signed .ipa>]
```

Signs the unsigned IPA (`unsigned.ipa` in the app's `output` folder by default) for the App Store with the pinned zsign in WSL2, and writes `signed.ipa` next to it only when every check of the result passes ([ADR-0013, phase 3a as built](../../docs/adr/0013-wincode-cli-build-sign-upload.md)). Before zsign runs:

| Check | What passes |
| --- | --- |
| `input` | The IPA holds one `Payload/<name>.app` of the bundle ID, nothing else, and no app extension or watch app (those need their own profiles: `extensions-unsupported`) |
| `local-profile` | As in `preflight` |
| `dist-key` | The app's distribution key (its credentials' `dist.key`, `WINCODE_DIST_KEY_<REF>`, or `WINCODE_DIST_KEY` for a flat file) is an unencrypted RSA key in PEM. An encrypted key or a `.p12` is refused (`key-encrypted`, 78); encrypted keys come in phase 3b. A key on the WSL2 disk (`\\wsl.localhost\...`) is refused too (`dist-key-unreachable`, 78), with where to move it |
| `certificate` | One of the profile's certificates has the key's public key, is an Apple Distribution certificate of the team, and has not expired. No certificate file is configured |
| `entitlements` | The app's `entitlements` plus `application-identifier`, `com.apple.developer.team-identifier`, `keychain-access-groups` and `get-task-allow` false, built as the spike's `sign.py` builds them, each allowed by the profile. `--verbose` prints them |
| `certificate-asc` | App Store Connect lists the certificate (`GET /v1/certificates`, by serial number) as a distribution certificate that has not expired. `--offline` skips this request with a WARN |
| `zsign` | The zsign in WSL2 is the pinned one, with the SHA-256 that `doctor --sign` recorded, and the key is readable there through `wslpath` |

The first five checks read local files and all run, so one report lists every local problem. App Store Connect is asked, and zsign is started, only when none of them failed. zsign then runs through `wsl.exe --exec` (no shell), with every path translated by `wslpath -u` and the key read in place: nothing key-related is written inside WSL2, and no password is ever passed (`-p` never is). Its files go to a temporary folder in the output folder, deleted whatever happens. After it, `code-signature` checks every signature as [`docs/formats/code-signature-verification.md`](../../docs/formats/code-signature-verification.md) describes, and preflight's local checks (`ipa`, `signature`, `profile-link`) run on the result. A failure leaves no file behind and an earlier `signed.ipa` as it was.

`--verify-only` runs the checks of the profile, the certificate and the entitlements, then `code-signature` and preflight's local checks, on a signed IPA (`signed.ipa` by default). It reads no private key: the certificate is the one that signed the app's executable, which must be one of the profile's certificates. App Store Connect is asked about it unless `--offline` is given. It needs no WSL2. `--all` is refused. `--dry-run` sends nothing, starts nothing and prints the zsign command with placeholders.

| Exit | Failure ids |
| --- | --- |
| 0 | `certificate-not-checked` (`--offline`, a warning), `der-entitlements-missing` (a warning) |
| 1 | `ipa-missing`, `ipa-unreadable`, `ipa-outside-payload`, `extensions-unsupported`, `bundle-id-mismatch`, `key-not-rsa`, `certificate-not-in-profile`, `certificate-not-distribution`, `certificate-team-mismatch`, `certificate-expired`, `certificate-not-in-asc`, `entitlement-not-allowed`, `zsign-failed`, `zsign-timeout`, `zsign-too-big`, `zsign-changed`, `zsign-unverified`, `signature-invalid`, and the failures of preflight's local checks |
| 69 | `wsl-missing`, `wsl-unreachable`, `zsign-missing`, `git-unavailable`, `offline`, `asc-unavailable` |
| 77 | `asc-unauthorized`, `asc-forbidden` |
| 78 | `profile-not-configured`, `dist-key-missing`, `dist-key-unreadable`, `dist-key-unreachable`, `key-encrypted`, `key-invalid`, `entitlements-unreadable`, `path-unreachable`, `asc-key-dir-missing`, `key-in-git-tree`, `key-in-onedrive` |

### The pinned zsign

`xtool-org/zsign` 1.9.0 at commit `f6158be9e62a5ce2a53d72b1a6d880880da956c8`, the one `third_party/xtool/Package.resolved` pins; GitHub's archive of it has the SHA-256 `423ebe2f4dd3380367461c03e6de3b9e9f31adcbe9a2f0237493c8f0bf9b7c5d`. zsign is MIT-licensed; it builds its own zlib and minizip (zlib licence) and links OpenSSL 3 (Apache-2.0). winCode ships none of them: `wincode doctor --sign` prints the commands that build it at `~/.wincode/zsign` in the distribution, and you run them. Set `WINCODE_WSL_DISTRO` when that is not the default distribution.

## upload

```
dart run wincode_cli:wincode upload [--app <name>] [--ipa <file>] [--timeout <minutes>] [--yes] [<signed .ipa>]
```

Built, and not yet exercised against App Store Connect from `wincode`: its tests run against a fake one, and the real run on a throwaway test app waits for the maintainer's word ([ADR-0013, phase 4 as built](../../docs/adr/0013-wincode-cli-build-sign-upload.md)). `wincode status` is not built yet.

Uploads the signed IPA (`signed.ipa` in the app's `output` folder, or `--ipa <file>`) through the Build Uploads API and waits for Apple's processing result. It is the only command that writes to Apple.

Before the first write, every check runs, and one that fails stops the command with nothing uploaded:

| Check | What passes |
| --- | --- |
| `preflight`, strict | Everything `preflight` checks, and an IPA that is not signed fails (`ipa-unsigned`) where `preflight` says INFO: the key, the app record, a build number above every existing build's, the App ID's active profile, the profile of `wincode.yaml`, the IPA, its signature and the profile link |
| `certificate`, `certificate-asc`, `code-signature` | What `sign --verify-only` checks: the certificate that signed the IPA is one of the profile's, a distribution certificate of the team that has not expired, and App Store Connect lists it; every signature, hash and seal of the IPA checks out |

Then it prints the plan (app, version and build number, file name and size, MD5 and SHA-256) and asks you to type the name of the app (the bundle ID for a `wincode.yaml` without names). `--yes` skips the question, and is needed without a terminal, in CI (`CI` set) and with `--json`, where `upload` refuses to ask (`confirmation-required`, 64). `--dry-run` sends nothing and asks nothing: it checks what needs no network, and prints the plan and the requests, as `asc_upload.py --dry-run` does.

The requests are the spike's, in its order: `GET /v1/apps`, `POST /v1/buildUploads`, `POST /v1/buildUploadFiles`, the parts of the file that Apple names, `PATCH /v1/buildUploadFiles/{id}` with the MD5, and `GET /v1/buildUploads/{id}` every 30 s until the build is valid or failed, or `--timeout` (minutes, or seconds with an `s`; 20 minutes by default) has passed. Each step and each change of state is printed with its UTC time, and Apple's messages as sent. Nothing that creates or changes something at Apple is retried: a repeat could make a second upload, and a build number that Apple has taken stays used. The parts and the reads of the state are, with a short backoff. The token, the key and the signed links of the parts are never printed.

| Exit | Failure ids |
| --- | --- |
| 0 | the build is valid |
| 1 | `ipa-unsigned` and the other failures of `preflight` and `sign --verify-only`, `upload-cancelled`, `upload-refused`, `upload-part-refused`, `upload-answer-invalid`, `app-record-missing`, `ipa-unreadable`, `ipa-changed` |
| 64 | `confirmation-required` |
| 65 | `processing-failed`: Apple took the file and then failed its processing. The build number is used |
| 69 | `offline`, `asc-unavailable`, `upload-part-unavailable` |
| 75 | `processing-timeout`: the file was sent and Apple had not finished within `--timeout`. The build may still become valid; do not upload the same build number again |
| 77 | `asc-unauthorized`, `asc-forbidden` |
| 78 | `asc-key-dir-missing` and the other key-location failures of `preflight` |

`upload` runs on Linux as well as on Windows; signing on Linux needs a native zsign runner, which is the next slice (ADR-0013, section 11).

## doctor

```
dart run wincode_cli:wincode doctor [--sign]
dart run wincode_cli:wincode doctor --binary <Mach-O file> [--sdk <iPhoneOS.sdk folder>] [--reference <Mach-O file>]
```

With `--sign`, `doctor` also checks, per app, what `sign` needs, each failure with its next step:
- WSL2 is installed, and the distribution (`WINCODE_WSL_DISTRO`, else the default one) exists, runs on WSL 2 and starts.
- The pinned zsign is built and prints its version; when it is missing, `doctor` prints the commands that build it.
- Its SHA-256 is the one recorded in `%LOCALAPPDATA%\wincode\zsign.json`. The first `doctor --sign` that finds it records it there; `sign` refuses to run before that, or once the binary changes.
- The app's distribution key is found, and WSL2 can read it through `wslpath`.

`doctor --sign` runs only read-only commands in WSL2 (`wslpath`, `printenv`, `test`, `sha256sum`, `zsign -v`), never `sudo` and never an install. It has no `--dry-run`, since it records the hash.

Without options, `doctor` checks the setup of the app in `wincode.yaml` and sends nothing (ADR-0014, section 3): `settings` (the file loads) and `credentials` (the App Store Connect key folder holds one `AuthKey_<Key ID>.p8` and an `issuer-id` with an Issuer ID, outside git working trees and OneDrive; the key itself is not read). Each check prints PASS or FAIL with the why and the next step, `--json` gives `checks` and `error` as for `preflight`, and the exit code is that of the first failure. A file of several apps exits with 64 until `--app` exists. This replaces the usage error that `doctor` without options gave before.

The Mach-O checks:

- `--sdk` checks the binary against the text stubs of the SDK folder (`docs/formats/macho-conformance.md`) and fails on a library or binding that its minimum OS lacks. On Windows, the folder that `xtool sdk` built in WSL2 is read through `\\wsl.localhost\<distribution>\home\<user>\.swiftpm\swift-sdks\darwin.artifactbundle\Developer\Platforms\iPhoneOS.platform\Developer\SDKs\iPhoneOS.sdk`.
- `--reference` lists how the binary differs from a reference build, such as an Xcode-built copy: libraries, weak or strong, bindings and load commands. It does not fail.

It exits with 0 when the checks pass, 1 when one fails or a file cannot be read, 64 for a usage error (such as `--binary` without `--sdk` or `--reference`), and 69 when `--sdk` names a folder that is not an SDK.

## The reference workflow

[`templates/wincode-ios.yml`](templates/wincode-ios.yml) is the workflow that `wincode build` will start in the app's repository (phase 5): it builds the unsigned IPA on a GitHub-hosted macOS runner and uploads it as the artifact `unsigned-ipa`. It has not been run yet.

## Tests

```
dart test
```

`test/goldens/help.txt` holds the `--help` output of every command. `test/goldens/config-flat.txt` holds what the loader says about a flat `wincode.yaml`, case by case; it was first written from the loader as it was before ADR-0014, so a change in it is a change in how a flat file is read. `test/init_migrate_test.dart` covers the in-place edits (`test/goldens/init-edit.txt` holds a hand-kept file before and after), the migration with and without a backup (`test/goldens/init-migration.txt`, redacted) and the rollback of a write that would not load. `test/apps_select_test.dart` covers `--app`, `--all` and `init --app` with files of three apps, and `test/goldens/apps-json.txt` holds the `--json` documents of one app and of `--all`, redacted too. `test/credentials_test.dart` uses real temporary git repositories for the keys-root rule, records every program that the resolution starts (only `git`), and reads the two messages of ADR-0014 that this change implements from the ADR itself. `test/config_apps_test.dart` reads the worked example and the duplicate-bundle-ID message from ADR-0014 itself, so the ADR and the code cannot drift. The tests of `init` build Flutter projects in a temporary folder, with a scripted standard input, and use a real temporary git repository for the profile rule. `test/goldens/init-messages.txt` holds what `init` prints when it cannot ask. `test/workflow_template_test.dart` fails if the embedded workflow (`lib/src/workflow_template.g.dart`) and `templates/wincode-ios.yml` differ by a byte. `test/goldens/preflight.txt` holds `preflight` reports and its `--dry-run` requests, and `test/goldens/preflight.json` its `--json` object, all from a fake App Store Connect on 127.0.0.1 with made-up IDs. `test/sign_test.dart` runs `sign` and `doctor --sign` against a fake `wsl.exe` and a fake zsign that signs, fails, hangs, writes garbage or grows, with throwaway RSA keys, self-made certificates and made-up profiles from `wincode_core`'s `testing.dart`, and checks that nothing is left behind after a failure; `test/goldens/sign.txt` holds a redacted report. The CI job `zsign integration` builds the pinned zsign on Ubuntu, signs an app that `tool/zsign_fixture.dart` generates with a throwaway CA, and runs `sign --verify-only` and `upload --dry-run` on it, so that Linux is tested from the start. `test/upload_test.dart` runs `upload` against a fake App Store Connect and a second fake for the upload store (the requests and their bodies, the parts rebuilding the IPA byte for byte, a part that fails and is sent again, a refused create that is not repeated, a failed processing, the timeout, each check that stops the run, `--dry-run` making no request, the confirmation, and that no token, key, link or signed header is ever printed), with an IPA that a throwaway key signed; `test/goldens/upload.txt` holds a redacted report. After a deliberate change, `UPDATE_GOLDENS=1 dart test` rewrites them; review the diff before committing. No test reaches the network.

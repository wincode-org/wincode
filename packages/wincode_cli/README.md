# wincode_cli

The `wincode` command. Its design is [ADR-0013](../../docs/adr/0013-wincode-cli-build-sign-upload.md).

Status: `doctor`, `preflight`, `init` and `sign` work, and `upload` is tested against a fake App Store Connect and exercised against App Store Connect from `wincode` (build 15, VALID). `preflight` and `doctor` read an app's App Store Connect key through its `credentials` reference (ADR-0014; layout below), and `sign` its distribution key. `sign` signs with an unencrypted PEM key only (ADR-0013, phase 3a); encrypted keys come in phase 3b. On Windows `sign` runs zsign in WSL2; on Linux it runs zsign directly, with no WSL2 (built, exercised on Linux CI with a throwaway certificate and on Linux (WSL2) with a real key; not yet run on a real server). `upload` needs no WSL2 and runs on Linux too. `build` makes every check that comes before a dispatch, prints its plan, asks, starts the workflow on a GitHub runner, follows the run, and downloads and checks its unsigned IPA ([ADR-0015](../../docs/adr/0015-wincode-build.md), parts 5a to 5c; tested against a fake GitHub, run end to end on the Linux workflow of a test repository, and exercised on a real macOS runner). The chain `build`, `sign`, `upload` was exercised end to end on a real macOS runner: build, sign, upload, VALID (test app, build 16); what that run did not show is listed in ADR-0015 ("The first macOS run"). `status` is registered; it prints `not implemented yet, see ADR-0013` and exits with 64 until its phase. `wincode.yaml` may describe several apps ([ADR-0014](../../docs/adr/0014-one-project-many-apps.md)): `--app <name>` chooses the app of `preflight`, `doctor` and `init`, `--all` runs `preflight` and `doctor` for every app, and `init --app` adds an app to a file of apps, or moves a flat file under `apps:` (below).

```
dart run wincode_cli:wincode <command> [arguments]
```

| Command | What it will do | Phase |
| --- | --- | --- |
| `init` | Write `wincode.yaml` for the Flutter project in this folder | works |
| `preflight [<signed .ipa>]` | Check the signed IPA and App Store Connect before an upload. Read-only | works |
| `sign [<unsigned .ipa>]` | Sign the IPA for the App Store with zsign (in WSL2 on Windows, directly on Linux), and check every signature | works (3a); Linux exercised on Linux (WSL2) with a real key |
| `upload [<signed .ipa>]` | Upload the signed IPA to App Store Connect and wait for its processing | built (4), exercised against App Store Connect (builds 15 and 16 of a test app, VALID) |
| `status` | Show the state of the app's latest uploads in App Store Connect. Read-only | 4 |
| `build` | Build the unsigned IPA on the app's macOS runner (GitHub Actions) and download it | built (5), exercised end to end on a real macOS runner: build, sign, upload, VALID (test app, build 16) |
| `doctor` | Check the setup (with `--sign`, what `sign` needs, and with `--build-zsign` on Linux, build the pinned zsign first; with `--build`, what `build` checks), or a Mach-O binary against the SDK or a reference build | works; `--build-zsign` built on Linux (3a.1), exercised on Linux (WSL2), not built on Windows |

## Global options

They go before or after the command.

- `--config <file>`: the app's settings, `wincode.yaml` by default (below).
- `--app <name>` and `--all`: which app of a `wincode.yaml` with an `apps:` map the command works on (below).
- `--json`: one JSON object on stdout when the command ends, with `command`, `app` (the name, or null for a flat file), `ok`, `exitCode`, the results, and on a failure `error` with `id`, `what`, `why` and `next`. Messages go to stderr. With `--all` it is one document (below).
- `--redact`: hide the bundle ID and team ID, and the names of apps, credentials references, flavors and the paths of the settings, in everything printed. It is always on when the `CI` environment variable is set (not empty, `0` or `false`). Commands register the IDs they learn with the redactor.
- `--verbose`: also print each step, external command and HTTP request, with secrets redacted.
- `--dry-run`: send, write and run nothing, and print what would be done.

`--events` is an option of `build`, `sign` and `upload` (ADR-0015, section 9): it writes one JSON object per line on stdout as the command goes, and ends with the object that `--json` prints plus `"event": "result"`. The messages for people go to stderr, and it cannot be combined with `--json` (64). The events and their fields are `eventFields` in `lib/src/events.dart`.

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
| 64 | Usage error (`--events` with `--json`, a commit as `--ref`), `build` without `--yes` where it cannot ask, a public repository without `--allow-public`, or not implemented yet |
| 65 | `upload`: Apple took the IPA and then failed its processing |
| 69 | A tool, the SDK or the network is missing; GitHub is down, or limits the token for longer than `build` waits |
| 70 | A bug in winCode |
| 75 | `upload`: Apple had not finished its processing within `--timeout`. `build`: the run was still going when winCode stopped waiting, at `--timeout` or after Ctrl-C |
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

A flat file may also hold `flavor`, `configuration` (which defaults to `Release-<flavor>`, or `Release`), `workflow_inputs`, `credentials`, and the four keys of `build` (ADR-0015, section 2):

| Key | What it is |
| --- | --- |
| `build_name` | The App Store version: one to three whole numbers joined by dots. Quote it (`"2.4"`): YAML reads 2.4 as a number. Without it, `pubspec.yaml`'s version at the ref gives it |
| `target` | The Dart entry point, a path under `lib/` ending in `.dart` (at most 64 characters). Without it, Flutter's `lib/main.dart` |
| `flutter_version` | The Flutter release that builds the app, as `flutter/flutter` tags it: `3.47.7`, or `3.48.0-0.1.pre`. `build` needs it |
| `min_xcode_version` | The oldest Xcode that may build the app, in quotes: `"26.0"`. `build` needs it |

`init`, `sign`, `preflight` and `upload` work without `flutter_version` and `min_xcode_version`; `build` stops without them (`flutter-version-missing`, `min-xcode-missing`, 78). Everything else about a flat file is as it was.

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
- `defaults` may hold `team_id`, `entitlements`, `workflow`, `workflow_inputs`, `credentials`, `build_name`, `target`, `flutter_version` and `min_xcode_version`. An app's own value replaces a default whole. `bundle_id`, `flavor`, `configuration`, `profile` and `output` are per app.
- Every app needs `bundle_id`, `team_id` and `credentials` (the name of a credentials reference; no command reads one yet). `output` defaults to `build/wincode/<app>`.
- An app name and a credentials reference have 3 to 32 lower-case letters, digits and hyphens, start with a letter and end with a letter or digit, and are not an ordinary word (`build`, `key`, `app`, `release`, ... `reservedNames` in `lib/src/config.dart` has the list), a Windows device name or the shape of a placeholder such as `app-1`.
- Bundle IDs are unique (ignoring case), output folders are unique, and one credentials reference serves one team. Messages name the line and, for a name that passed its rules, the app; a refused name is never printed.
- `workflow_inputs` names are plain, not `request_id`, `flavor`, `build_number`, `build_name`, `target`, `flutter_version` or `min_xcode_version`, which `build` sets itself, and not secret-looking; values are at most 64 plain characters, and there are at most 18 entries.
- `loadSettings` and `parseSettings` return every app in file order (`WincodeSettings`). `loadConfig` returns the one app that existing commands work on, and refuses a file of several with exit 64 (`not-implemented`).
- With a `Redactor`, the loader registers the names, bundle IDs, team IDs, credentials references, flavors, configurations and the `profile`, `entitlements` and `output` paths as soon as each has passed its checks, so that `--redact` and CI print `app-1`, `<bundle ID 1>`, `credentials-1`, `Release-app-1`, `<profile of app-1>` and `<output of app-1>/signed.ipa` even in an error message (ADR-0014, section 4). `preflight` passes its redactor to the loader.

Secrets come only from environment variables, which name files outside the project: `WINCODE_ASC_KEY_DIR` (the App Store Connect key folder) and `WINCODE_DIST_KEY` (the distribution key, a file on a Windows drive that zsign reads in place). `preflight` reads `WINCODE_ASC_KEY_DIR` and `sign` both (ADR-0013, section 2). A key or profile file inside a git working tree is refused unless git ignores it: `requireOutsideGit` does the check, and `preflight` calls it on each file of the key folder that it reads and on the profile, `init` on the profile, and `sign` on the distribution key and the profile, before reading them. On Linux (any POSIX system), a keys folder, a `dist.key` and a `.p8` that the group or others can read or write, or that another user owns, are refused too, like ssh refuses a private key ([the rule](#keys-closed-to-other-users-linux)).

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

#### Keys closed to other users (Linux)

On a POSIX system, every command that reads a key (`sign`, `preflight`, `upload`, `doctor`) first refuses keys that other users could reach, because on a shared server a key is only as private as its mode (ADR-0013, section 11). The rule is the one of ssh:

- **A file** (`dist.key`, `AuthKey_<Key ID>.p8`, or the file that `WINCODE_DIST_KEY` or `WINCODE_DIST_KEY_<REF>` names) needs mode 0600 or tighter. **A folder** (the keys root, the folder of a reference, or the folder that `WINCODE_ASC_KEY_DIR` or `WINCODE_ASC_KEY_DIR_<REF>` names) needs 0700 or tighter. One bit for the group or for others refuses it. A link is checked as the file it points to.
- **The owner** must be the user that runs `wincode`. When `id` or `stat` cannot tell who owns a file, the check fails closed (`stat-unavailable`, 69).
- It fails with `keys-permissions` (78). The message names the file by what it is (never its path, and never the Key ID) and gives the fix, such as `run: chmod 600 ~/.wincode/keys/team-one/dist.key` or `run: chmod 700 "$WINCODE_KEYS_DIR"`; for a file that another user owns, `run: sudo chown "$(id -un)" <file> && chmod 600 <file>`. It never prints any content of a key.
- `doctor` reports it as a FAIL of the check that reads the key (`credentials` or `dist-key`), and goes on with its other checks.
- Windows is skipped: the user profile is the boundary there.


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

At a terminal, `init` shows each value with what it found (Enter accepts it, `-` leaves an optional one out) and asks before it writes. With `--yes`, with `--json`, with `CI` set, or when standard input is not a terminal that can be read (on Windows, the null device and a console that was never attached are not), it asks nothing: give every field as an option, or `--yes` to accept what it found. Otherwise it fails with exit 64 (`init-input-missing`) and says, for each value that is not settled, `detected <value> in <source>; confirm with --yes or pass --<option>`, `detected several (...); pass --<option>`, or `not detected; pass --<option>`.

If the project has build configurations other than Debug, Profile and Release (for example one per flavor) and you gave neither `--flavor` nor `--configuration`, `init` prints a `WARN` that lists them and says that it read Release. `--configuration <name>` has no counterpart in `wincode.yaml`. A name that the project does not have fails (`configuration-not-found`, exit 1) and lists the names it has.

With `--flavor` or `--configuration`, `init` prints `Read the build configuration <name> of ios/Runner.xcodeproj.` (and `--json` has `"configuration"`). `--flavor` and `--configuration` may be combined: `--flavor` is recorded (`flavor:`) and names the default configuration, `Release-<flavor>`, and `--configuration` overrides it and is recorded (`configuration:`) only when it is another name. `--credentials <name>` records the credentials reference. A `$(NAME)` or `${NAME}` in the bundle ID, the team ID or the entitlements file is resolved without running anything: from the build settings of that configuration, from the xcconfig files it references and their `#include` and `#include?` chains (16 deep at most; a file that includes itself fails at once and is named), and from nested variables. A variable that nothing defines is listed (`PRODUCT_BUNDLE_IDENTIFIER of Release-alpha needs $(APP_ID), which no build setting or xcconfig file of Release-alpha defines`) and asked, never guessed; a run that cannot ask fails with `not detected ($(APP_ID) is not defined in Release-alpha or its xcconfig files); pass --bundle-id`.

- **`--app <name>`** (ADR-0014, section 5) works on a file of apps. Without a `wincode.yaml` it starts one with that app; with one it adds the app, or updates its entry, after showing the changes with `-` and `+` and asking (`--yes` where it cannot ask; without it, `init-input-missing`, 64, and nothing is written). A value that the entry already has is replaced only with `--force` (`app-exists`, exit 1, otherwise). A value that equals the one the entry inherits from `defaults` is left out, `defaults` is never touched, and `credentials` is required (asked, or `--credentials`). The file is edited in place (`yaml_edit`): comments, blank lines and key order stay, and only the entry changes. Without `--app`, a file of apps is `app-required`, and `--app` on a flat file moves it under `apps:` (below). `--all` is refused.
- **An existing `wincode.yaml` is kept** (`config-exists`, exit 1) and the lines that would change are shown with `-` and `+`; `--force` replaces it.
- **A profile in a git working tree that git does not ignore is refused** (`key-in-git-tree`, exit 78) before it is read. A profile inside the project gets a suggested `.gitignore` line; `init` never edits `.gitignore`.
- **`--dry-run`** prints the file and writes nothing. **`--redact`** and `CI` hide the bundle ID and team ID in everything printed; the file keeps the real values.
- **`--workflow`** writes `.github/workflows/wincode-ios.yml`, or updates the one that is there (ADR-0015, section 8). Without `--app` it changes the workflow only, and takes none of the options that describe `wincode.yaml` (`init-value-invalid`, 64). A new file is written byte for byte. With an existing one, `init` shows the differences with `-` and `+`, keeps the old file's `XCODE_APP`, `runs-on` and `timeout-minutes` (a value that is not well formed is not kept, and a note says so), moves its `FLUTTER_VERSION` to `flutter_version` in `wincode.yaml` when that has none (a note when they differ; `wincode.yaml` wins), asks `[y/N]` (default no; `--yes` where it cannot ask, otherwise `init-input-missing`, 64, and nothing is written; `--force` is not a yes), copies the old file byte for byte to `wincode-ios.yml.bak` (`backup-exists`, 1, unless `--force`), and writes the new one. A workflow that is already the template is "up to date" and nothing is written; one that says a newer contract is refused (`workflow-contract`, 78), and one that is not a workflow is `workflow-unreadable` (78). `--dry-run` shows the changes only. `init` writes no other file, runs no `git` command and does not push: that stays your step. The text is built into `wincode`, so a compiled `wincode` needs no checkout. `templates/wincode-ios.yml` is the readable source: after changing it, run `dart run tool/embed_template.dart` in `packages/wincode_cli`, and a test fails if the two differ.
- It ends with the commands to run next: `wincode preflight --dry-run`, then `wincode preflight`.
- With `--json`, stdout gets `{"command": "init", "app": null, "ok": true, "exitCode": 0, "dryRun": false, "written": true, "config": {...}}`, with `"warnings"` (a list) when `init` warned, and `"workflow": "copied"`, `"would-copy"`, `"updated"`, `"would-update"` or `"up-to-date"` (and `"backup"`, and `"flutter_version"` under `"config"`, when they apply) when `--workflow` was given; the report goes to stderr.

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

Signs the unsigned IPA (`unsigned.ipa` in the app's `output` folder by default) for the App Store with the pinned zsign, and writes `signed.ipa` next to it only when every check of the result passes ([ADR-0013, phase 3a as built](../../docs/adr/0013-wincode-cli-build-sign-upload.md)). On Windows zsign runs in WSL2; on Linux it runs directly on the machine ([ADR-0013, section 10, "Linux signing"](../../docs/adr/0013-wincode-cli-build-sign-upload.md)); the checks and the output are the same. Before zsign runs:

| Check | What passes |
| --- | --- |
| `input` | The IPA holds one `Payload/<name>.app` of the bundle ID, nothing else, and no app extension or watch app (those need their own profiles: `extensions-unsupported`) |
| `local-profile` | As in `preflight` |
| `dist-key` | The app's distribution key (its credentials' `dist.key`, `WINCODE_DIST_KEY_<REF>`, or `WINCODE_DIST_KEY` for a flat file) is an unencrypted RSA key in PEM. An encrypted key or a `.p12` is refused (`key-encrypted`, 78); encrypted keys come in phase 3b. A key on the WSL2 disk (`\\wsl.localhost\...`) is refused too (`dist-key-unreachable`, 78), with where to move it |
| `certificate` | One of the profile's certificates has the key's public key, is an Apple Distribution certificate of the team, and has not expired. No certificate file is configured |
| `entitlements` | The app's `entitlements` plus `application-identifier`, `com.apple.developer.team-identifier`, `keychain-access-groups` and `get-task-allow` false, built as the spike's `sign.py` builds them, each allowed by the profile. `--verbose` prints them |
| `certificate-asc` | App Store Connect lists the certificate (`GET /v1/certificates`, by serial number) as a distribution certificate that has not expired. `--offline` skips this request with a WARN |
| `zsign` | The zsign (in WSL2, or on this Linux machine) is the pinned one, with the SHA-256 that `doctor --sign` recorded, and the key is readable by it (through `wslpath` in WSL2) |

The first five checks read local files and all run, so one report lists every local problem. App Store Connect is asked, and zsign is started, only when none of them failed. zsign then runs through `wsl.exe --exec` (no shell), with every path translated by `wslpath -u` and the key read in place: nothing key-related is written inside WSL2, and no password is ever passed (`-p` never is). Its files go to a temporary folder in the output folder, deleted whatever happens. After it, `code-signature` checks every signature as [`docs/formats/code-signature-verification.md`](../../docs/formats/code-signature-verification.md) describes, and preflight's local checks (`ipa`, `signature`, `profile-link`) run on the result. A failure leaves no file behind and an earlier `signed.ipa` as it was.

**On Linux**, `sign` has no WSL2 and no path to translate. It starts the pinned binary itself, as a process with an argument list (`Process.start`, never a shell, never `-p`), working in a temporary folder inside the output folder. That folder is made with `chmod 700` before anything goes into it (`dart:io` makes folders with the umask; if `chmod` cannot run, `sign` stops with `chmod-unavailable`, 69; where the filesystem ignores `chmod`, such as WSL2's `/mnt/c`, the folder stays open, and it holds no key, so keep the output folder on the Linux disk on a server), and it is deleted in a `finally` whatever happened. The PEM key is read in place, at the path it has: it is never copied. Its certificate is the one of the profile, as on Windows. zsign gets the certificate as a PEM file, so for the chain it uses the Apple intermediate that it embeds for the certificate's issuer. On macOS `sign` stops with `platform-unsupported` (69); `sign --verify-only`, `preflight` and `upload` need no zsign and work there as on Linux.

`--verify-only` runs the checks of the profile, the certificate and the entitlements, then `code-signature` and preflight's local checks, on a signed IPA (`signed.ipa` by default). It reads no private key: the certificate is the one that signed the app's executable, which must be one of the profile's certificates. App Store Connect is asked about it unless `--offline` is given. It needs no WSL2 and no zsign. `--all` is refused. `--dry-run` sends nothing, starts nothing and prints the zsign command with placeholders.

| Exit | Failure ids |
| --- | --- |
| 0 | `certificate-not-checked` (`--offline`, a warning), `der-entitlements-missing` (a warning) |
| 1 | `ipa-missing`, `ipa-unreadable`, `ipa-outside-payload`, `extensions-unsupported`, `bundle-id-mismatch`, `key-not-rsa`, `certificate-not-in-profile`, `certificate-not-distribution`, `certificate-team-mismatch`, `certificate-expired`, `certificate-not-in-asc`, `entitlement-not-allowed`, `zsign-failed`, `zsign-timeout`, `zsign-too-big`, `zsign-changed`, `zsign-unverified`, `signature-invalid`, and the failures of preflight's local checks |
| 69 | `wsl-missing`, `wsl-unreachable`, `zsign-missing`, `platform-unsupported`, `chmod-unavailable`, `stat-unavailable`, `git-unavailable`, `offline`, `asc-unavailable` |
| 77 | `asc-unauthorized`, `asc-forbidden` |
| 78 | `profile-not-configured`, `dist-key-missing`, `dist-key-unreadable`, `dist-key-unreachable`, `key-encrypted`, `key-invalid`, `entitlements-unreadable`, `path-unreachable`, `asc-key-dir-missing`, `key-in-git-tree`, `key-in-onedrive`, `keys-permissions` (Linux) |

### The pinned zsign

`xtool-org/zsign` 1.9.0 at commit `f6158be9e62a5ce2a53d72b1a6d880880da956c8`, the one `third_party/xtool/Package.resolved` pins; GitHub's archive of it has the SHA-256 `423ebe2f4dd3380367461c03e6de3b9e9f31adcbe9a2f0237493c8f0bf9b7c5d`. zsign is MIT-licensed; it builds its own zlib and minizip (zlib licence) and links OpenSSL 3 (Apache-2.0). winCode ships none of them: `wincode doctor --sign` prints the commands that build it, and you run them. On Windows they build at `~/.wincode/zsign` in the WSL2 distribution (set `WINCODE_WSL_DISTRO` when that is not the default one) and the SHA-256 is recorded in `%LOCALAPPDATA%\wincode\zsign.json`. On Linux they build at `zsign/zsign-<commit>/bin/zsign` under `$XDG_DATA_HOME/wincode` (`~/.local/share/wincode` when it is not set), next to the record, `zsign.json`. `wincode sign` runs only a binary whose SHA-256 is the recorded one (trust on first use: the first `doctor --sign` that finds it records it). On Linux, `doctor --sign --build-zsign` builds it for you instead, from the archive it downloads and checks, and records the SHA-256 of what it built ([below](#doctor)); on Windows that is not built yet, and you run the printed commands in WSL2.

## upload

```
dart run wincode_cli:wincode upload [--app <name>] [--ipa <file>] [--timeout <minutes>] [--yes] [<signed .ipa>]
```

Built, tested against a fake App Store Connect, and exercised against App Store Connect from `wincode` (build 15, VALID): the maintainer ran it on a throwaway test app ([ADR-0013, phase 4 as built](../../docs/adr/0013-wincode-cli-build-sign-upload.md)). `wincode status` is not built yet.

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

`upload` runs on Linux as well as on Windows, and so does `sign` (above).

## build

```
dart run wincode_cli:wincode build [--app <name>] [--ref <branch or tag>] [--build-name <x.y.z>] [--build-number <n>|auto]
                                   [--timeout <minutes>] [--yes] [--allow-public] [--events] [--run <id>]
```

`build` reads the project at the commit of the ref through GitHub's REST API (version 2026-03-10), makes the checks below, prints its plan, and asks `Start this build on GitHub? It uses macOS minutes. [y/N]`. Then it starts the workflow once, reads the run every 30 seconds until it ends, downloads the artifact, checks it, and puts the unsigned IPA in the app's output folder as `unsigned.ipa`, which `sign` reads by default. Each step of the chain keeps its own exit code and question:

```sh
wincode build --app alpha --yes && wincode sign --app alpha && wincode upload --app alpha
```

| Option | What it does |
| --- | --- |
| `--yes` | Start without the question. Needed in CI, with `--json` or `--events`, and without a terminal: otherwise `confirmation-required` (64), before any request |
| `--timeout <minutes>` | How long to wait for the run, from the dispatch: 60 by default, or seconds with an `s`. It ends the wait, never the run: exit 75 `run-timeout` |
| `--run <id>` | Start nothing: wait for run `<id>`, which an earlier `build` started, then download and check its IPA. It needs only the workflow, the token and the repository, and checks the IPA against the version and build number in the run's name. Cannot be combined with `--ref`, `--build-name`, `--build-number` or `--dry-run` |
| `--allow-public` | Build in a public repository. winCode deletes the artifact once the IPA is in place |

**The run is never started twice, and never cancelled unasked.** If the answer to the dispatch is lost, the run may exist: `build` says so (`offline`, 69), names the run to look for, and does not send the dispatch again. Ctrl-C at a terminal asks `Cancel the run on GitHub too?` (default no; Enter, anything but `y` and a second Ctrl-C are a no) and exits 75 (`wait-stopped`) with the command that collects the run; with `--json` or `--events`, or on SIGTERM, it asks nothing. A run that builds another commit than the one the checks read stops the build with `ref-moved` (1), reports the run, downloads nothing and cancels nothing.

**The artifact** is downloaded through the redirect without the token, and checked in this order: the zip's SHA-256 against the `digest` that GitHub reports (`artifact-integrity`), the zip's files (`artifact-content`), the IPA's SHA-256 against the hash that the build job recorded (`artifact-integrity`), and the IPA itself: one app, the bundle ID of the app, no `embedded.mobileprovision` (`ipa-signed`), and the version and build number that were asked for (`ipa-version-mismatch`). `unsigned.ipa` is replaced only when every check passed.

`--events` writes `dispatched`, `run`, `job`, `step`, `wait` (every 60 seconds, with the minutes the jobs have used so far), `artifact` and `ipa` events as they happen, and ends with the object that `--json` prints. The text for people (one line each time the run, a job or a step changes) goes to stderr. The result has `runId`, `runUrl`, `conclusion`, `ipa` and `minutes`.

The token is looked for in `WINCODE_GH_TOKEN_<APP>` (the app's name in capitals, `-` written as `_`; none for a flat file), `GH_TOKEN`, `GITHUB_TOKEN`, then `gh auth token`. It goes to `api.github.com` only, is registered with the redactor as a secret, and is never printed. A fine-grained token with Actions (read and write), Contents (read) and Metadata (read) on the repository is the least it needs.

The checks, in order, each with the id of its failure (ADR-0015, sections 2, 3 and 8):

| Check | Fails with |
| --- | --- |
| `workflow:`, `flutter_version` and `min_xcode_version` are set | `workflow-missing`, `flutter-version-missing`, `min-xcode-missing` (78) |
| The token | `github-token-missing`, `github-unauthorized`, `github-forbidden` (77); `github-token-invalid` (78) |
| The repository can be read, and is private (or `--allow-public` is given) | `repository-not-found` (78), `repository-public` (64) |
| The workflow is on the default branch and active | `workflow-not-found`, `workflow-disabled` (78) |
| The ref is a branch or a tag; every file below is read at its commit | `ref-not-found` (78), `ref-is-commit` (64) |
| The Flutter project is at the root | `project-not-found` (78) |
| The workflow says `# wincode-workflow-contract: 2`, declares every input that `build` sends, and requires no other | `workflow-contract`, `workflow-input-unknown`, `workflow-input-missing`, `workflow-unreadable` (78). A WARN, `workflow-differs`, when a contract 2 workflow differs from the template (comments, key order, input descriptions, `runs-on`, `timeout-minutes` and `XCODE_APP` do not count); the build goes on |
| The workflow's `XCODE_APP` is not older than `min_xcode_version` | `xcode-too-old` (78); a WARN when it names no version |
| `pubspec.yaml`'s `environment: flutter:` allows `flutter_version` (pub's rules) | `flutter-version-mismatch` (78) |
| `flutter/flutter` has a tag `flutter_version` (one read) | `flutter-version-not-found` (78) |
| A version: `--build-name`, `build_name`, or `pubspec.yaml`'s | `build-name-missing` (78) |
| The entry point is in the repository | `target-missing` (78) |
| The scheme and configuration that Flutter 3.47 would build exist and are the app's | `scheme-missing`, `configuration-mismatch` (78) |
| The configuration's `PRODUCT_BUNDLE_IDENTIFIER` is `bundle_id` | `bundle-id-mismatch` (1); a WARN when it cannot be resolved |
| No run of the app is going, and the number is above every one that is known | `build-in-progress`, `build-number-not-higher`, `build-number-auto` (1), `build-number-missing`, `credentials-missing` (78) |

The build number is `--build-number <n>`, or `auto`, or by default `auto` in a file of apps and `pubspec.yaml`'s `+N` in a flat file. `auto` is one above the highest build number that App Store Connect has for the app (its builds and its build uploads, read with the app's credentials) and that the app's successful runs of the last 24 hours carry; the run's name, `wincode <app tag>-<version>-<number>-<random>`, holds the number, and the app tag is a hash of the bundle ID.

`--dry-run` sends no request and starts no program: it prints the plan from `wincode.yaml` and the options, with a placeholder for what only GitHub or App Store Connect can say, and the dispatch request as it would go out. `wincode doctor --build` makes the same checks and prints no plan, and starts nothing.

### Troubleshooting the GitHub token

`build` and `doctor --build` need a fine-grained personal access token with, on the app's repository, **Actions: read and write**, **Contents: read** and **Metadata: read**. A real run on a macOS runner met these three mistakes (ADR-0015, "The first macOS run"):

| What `wincode` says | Why | Fix |
| --- | --- | --- |
| `repository-not-found` (78): "GitHub has no repository `<owner>/<repo>`, or the token cannot see it" (GitHub answered 404) | The token's resource owner is not the organization that owns the private repository, and a fine-grained token sees only the repositories of its own resource owner | Make the token again with the organization as its resource owner |
| The same `repository-not-found` | The repository is not selected in the token's repository access | Edit the token and select `<owner>/<repo>` under repository access |
| `github-forbidden` (77): 403 "Resource not accessible by personal access token", at the dispatch | The token lacks Actions: read and write. Nothing was started | Add Actions: read and write to the token's permissions for the repository |

- **`doctor --build` cannot catch the third.** It passes with a token that lacks Actions write: every request that needs that permission changes something, so it is not tested ahead, and an INFO line (`actions-write`) says so. Only the dispatch finds out, before any run starts.
- **With `--redact` (and in CI),** a message that names the app's variable shows the app's placeholder in it, for example `WINCODE_GH_TOKEN_APP_1` for the first app of the file. Set the variable under the app's real name: `WINCODE_GH_TOKEN_<APP>`, the name in capitals with `-` written as `_`.

## doctor

```
dart run wincode_cli:wincode doctor [--sign [--build-zsign]] [--build]
dart run wincode_cli:wincode doctor --binary <Mach-O file> [--sdk <iPhoneOS.sdk folder>] [--reference <Mach-O file>]
```

With `--build`, `doctor` also makes, per app, every check that `build` makes before a dispatch (above), reading GitHub and, for the build number, App Store Connect, and starts nothing. A public repository is a WARN there, since `--allow-public` is an option of `build`. It has no `--dry-run`, and `--app` and `--all` choose the apps as for the other checks.

With `--sign`, `doctor` also checks, per app, what `sign` needs, each failure with its next step. On Windows:
- WSL2 is installed, and the distribution (`WINCODE_WSL_DISTRO`, else the default one) exists, runs on WSL 2 and starts.
- The pinned zsign is built and prints its version; when it is missing, `doctor` prints the commands that build it.
- Its SHA-256 is the one recorded in `%LOCALAPPDATA%\wincode\zsign.json`. The first `doctor --sign` that finds it records it there; `sign` refuses to run before that, or once the binary changes.
- The app's distribution key is found, and WSL2 can read it through `wslpath`.

On Linux there is no WSL2 to check: `platform` passes, the pinned zsign is looked for under `$XDG_DATA_HOME/wincode` (the commands that build it are printed when it is missing), its SHA-256 is the one recorded in `zsign.json` there (recorded by the first `doctor --sign` that finds it), and the distribution key is found, closed to other users, and readable. On macOS the `platform` check fails with `platform-unsupported` (69).

`doctor --sign` runs only read-only commands (in WSL2 on Windows: `wslpath`, `printenv`, `test`, `sha256sum`, `zsign -v`; on Linux: `zsign -v` and a SHA-256 read in Dart), never `sudo` and never an install. It has no `--dry-run`, since it records the hash.

### `--build-zsign` (Linux)

With `--sign` (it is a usage error alone), on Linux, `doctor` first builds the pinned zsign itself instead of asking you to run the printed commands, and then makes the `--sign` checks, which find it. This is [ADR-0013, phase 3a.1](../../docs/adr/0013-wincode-cli-build-sign-upload.md), the Linux half. It runs the printed commands, read from the same list in the code (`zsignBuildCommandsIn`), with the three steps that handle bytes you did not write done by `wincode` and not by a shell. The report has one finding per step:

| Finding | What it did |
| --- | --- |
| `zsign-build-tools` | `g++` (or, where there is none, `clang++` and `clang`, with `CXX=clang++ CC=clang` added to the `make` line as the printed line says), `make`, `pkg-config` and the OpenSSL development files (`pkg-config --exists openssl`) are there. When one is not, it stops here, **before downloading anything**, says which, and prints the command to run by hand (on Debian or Ubuntu `sudo apt-get install g++ pkg-config libssl-dev`, naming only what is missing). It installs nothing and never runs `sudo`. |
| `zsign-archive` | Downloaded GitHub's archive of the pinned commit: HTTPS only (a redirect is followed only to HTTPS, no credential is sent), at most 64 MiB (the archive is 23.6 MB), at most 30 s without data and 10 minutes in all, into a new folder of mode 0700 under `$XDG_DATA_HOME/wincode/zsign`. Its SHA-256 is checked **before anything is unpacked**. |
| `zsign-unpack` | Unpacked it with a reader of `wincode`'s own: only files and folders, every path under the build folder (no `..`, no absolute path or drive letter, no backslash), no link of any kind, no device, at most 20,000 entries and 256 MiB. |
| `zsign-build` | Ran `make` as the printed commands have it, as you, with an argument list and no shell. |
| `zsign-version` | The binary it built prints `version: 1.9.0`. |
| `zsign-record` | Put the new tree in place of the old one by a rename, and recorded the SHA-256 of the new binary in `zsign.json`, replacing the record that an earlier `doctor --sign` made from a binary it found in place. The record gets a `built` entry (the commit and the archive's SHA-256), which is how the next run knows that this command built it. `sign` still refuses a binary whose hash differs from the record. |

The old zsign stays where it was until the new one has been built and has passed the version check; if anything fails after that, it is put back, with its record. A run that fails leaves the previous install and its record as they were.

| `id` | Exit | When |
| --- | --- | --- |
| `zsign-build-tools-missing` | 1 | a tool of the build is missing; nothing was downloaded |
| `zsign-archive-mismatch` | 1 | the download's SHA-256 is not the pinned one; the download is deleted, nothing was unpacked or built |
| `zsign-archive-unsafe` | 1 | the archive could not be unpacked safely (a path outside the folder, a link, too large, not a tar.gz) |
| `zsign-build-failed` | 1 | `make` failed or made no binary, the binary prints another version, or the new tree could not be put in place; the last lines of the build are shown |
| `zsign-download-refused` | 1 | the answer is not HTTP 200, the address is not HTTPS, or the archive is larger than the limit |
| `offline`, `github-unavailable` | 69 | no answer within the timeout, or HTTP 5xx |
| `chmod-unavailable` | 69 | the build folder could not be made private |
| `not-implemented` | 64 | on Windows: it will build in WSL2, which is not built yet |
| `platform-unsupported` | 69 | on macOS, as for `sign` |

When this command built the pinned zsign before and it is unchanged (the pinned version, the recorded SHA-256, and a `built` entry for this archive), it says so and does nothing. `doctor` has no `--force`, so to build it again, delete the folder `zsign-<commit>` under `$XDG_DATA_HOME/wincode/zsign`, which the message names, and run the command again. `--dry-run` prints the plan (the address, the pinned SHA-256, the folder, the `make` line and the printed commands) and does nothing: no request, no program, no file, and no `wincode.yaml` is read. `--json` gives the findings as for the other checks, `--redact` (and CI) hide the folders, and `--all` builds once, in the report of the first app. The exit code is that of the first failure.

What `--build-zsign` does not do: build on Windows (the half that builds in WSL2 is not built), install a tool, take a lock against two runs at once, or remove the build folder that a Ctrl-C leaves behind (`.build-*` under the zsign folder; delete it).

Without options, `doctor` checks the setup of the app in `wincode.yaml` and sends nothing (ADR-0014, section 3): `settings` (the file loads) and `credentials` (the App Store Connect key folder holds one `AuthKey_<Key ID>.p8` and an `issuer-id` with an Issuer ID, outside git working trees and OneDrive; the key itself is not read). Each check prints PASS or FAIL with the why and the next step, `--json` gives `checks` and `error` as for `preflight`, and the exit code is that of the first failure. A file of several apps exits with 64 until `--app` exists. This replaces the usage error that `doctor` without options gave before.

The Mach-O checks:

- `--sdk` checks the binary against the text stubs of the SDK folder (`docs/formats/macho-conformance.md`) and fails on a library or binding that its minimum OS lacks. On Windows, the folder that `xtool sdk` built in WSL2 is read through `\\wsl.localhost\<distribution>\home\<user>\.swiftpm\swift-sdks\darwin.artifactbundle\Developer\Platforms\iPhoneOS.platform\Developer\SDKs\iPhoneOS.sdk`.
- `--reference` lists how the binary differs from a reference build, such as an Xcode-built copy: libraries, weak or strong, bindings and load commands. It does not fail.

It exits with 0 when the checks pass, 1 when one fails or a file cannot be read, 64 for a usage error (such as `--binary` without `--sdk` or `--reference`), and 69 when `--sdk` names a folder that is not an SDK.

## The reference workflow

[`templates/wincode-ios.yml`](templates/wincode-ios.yml) is the workflow that `wincode build` starts in the app's repository (phase 5): it builds the unsigned IPA on a GitHub-hosted macOS runner and uploads it as the artifact `unsigned-ipa`. It has run on a macOS runner once, for a made-up test app: the build, sign and upload that followed ended VALID, and the `awk` comparison of its Xcode step passed for one case (26.6 against 26.0). Other versions of macOS's `awk`, a flavor and a full-size IPA are untested ([ADR-0015](../../docs/adr/0015-wincode-build.md), "The first macOS run"). It is contract 2 (`# wincode-workflow-contract: 2`): it takes the seven inputs that `build` sends, checks the oldest Xcode with POSIX `awk`, clones the Flutter tag shallow, writes the IPA's SHA-256 beside it and into the step summary, keeps the artifact for one day, and reads no secret. Its two actions are pinned to a commit and are refreshed by hand. The owner of the repository sets `XCODE_APP`, `runs-on` and `timeout-minutes`. `build` refuses a workflow that is not at contract 2 (`workflow-contract`), and warns (`workflow-differs`) when a contract 2 workflow differs from the template in anything else; `init --workflow` shows how.

## Tests

```
dart test
```

`test/goldens/help.txt` holds the `--help` output of every command. `test/goldens/config-flat.txt` holds what the loader says about a flat `wincode.yaml`, case by case; it was first written from the loader as it was before ADR-0014, so a change in it is a change in how a flat file is read. `test/init_migrate_test.dart` covers the in-place edits (`test/goldens/init-edit.txt` holds a hand-kept file before and after), the migration with and without a backup (`test/goldens/init-migration.txt`, redacted) and the rollback of a write that would not load. `test/apps_select_test.dart` covers `--app`, `--all` and `init --app` with files of three apps, and `test/goldens/apps-json.txt` holds the `--json` documents of one app and of `--all`, redacted too. `test/credentials_test.dart` uses real temporary git repositories for the keys-root rule, records every program that the resolution starts (only `git`), and reads the two messages of ADR-0014 that this change implements from the ADR itself. `test/config_apps_test.dart` reads the worked example and the duplicate-bundle-ID message from ADR-0014 itself, so the ADR and the code cannot drift. The tests of `init` build Flutter projects in a temporary folder, with a scripted standard input, and use a real temporary git repository for the profile rule. `test/goldens/init-messages.txt` holds what `init` prints when it cannot ask. `test/workflow_template_test.dart` fails if the embedded workflow (`lib/src/workflow_template.g.dart`) and `templates/wincode-ios.yml` differ by a byte, checks the template's contract, inputs, pins (two actions, each `@<40 hex> # vX.Y.Z`), the absence of `${{` in any `run:` and of secrets, and the artifact, and, on Linux, runs the template's Xcode step under `sh` with stubs for `sudo` and `xcodebuild` and every `awk` that the machine has (set `WINCODE_TEST_AWK_DIRS` to add folders; macOS's own `awk` is not testable there). `test/init_workflow_test.dart` covers the update of a workflow (`test/goldens/init-workflow.txt` holds one before and after). `test/fake_github.dart` serves the real template as the repository's workflow, so every test of `build` also shows that the template passes its checks. `test/goldens/preflight.txt` holds `preflight` reports and its `--dry-run` requests, and `test/goldens/preflight.json` its `--json` object, all from a fake App Store Connect on 127.0.0.1 with made-up IDs. `test/sign_test.dart` runs `sign` and `doctor --sign` against a fake `wsl.exe` and a fake zsign that signs, fails, hangs, writes garbage or grows, with throwaway RSA keys, self-made certificates and made-up profiles from `wincode_core`'s `testing.dart`, and checks that nothing is left behind after a failure; `test/goldens/sign.txt` holds a redacted report. `test/key_permissions_test.dart` checks the key-permission rule with real temporary files and `chmod` (skipped on Windows), and the owner with a fake `stat`; `test/zsign_native_test.dart` the platform choice (Windows gets WSL2, Linux gets zsign itself, macOS is refused), the command line of the native runner, the pinned binary and its record under the XDG data folder, and `doctor --sign` on Linux; the group "on Linux, zsign runs directly" of `test/sign_test.dart` signs with a fake zsign that is started directly (an argument list, no `-p`, the key path as given, a temporary folder of mode 0700, nothing left behind after a failure, a timeout or a start that throws). `test/zsign_build_test.dart` runs `doctor --sign --build-zsign` against a fake download that serves a tiny source archive whose SHA-256 the test pins, and a fake `make`, `g++` and `pkg-config` (the success path and its record, an older record replaced, the second run that does nothing, a download that is not the pinned one refused before anything is unpacked, a missing tool stopping the command before any download, a failed build, a wrong version and a record that cannot be written leaving the old install, `--dry-run`, `--json`, `--redact`, Windows and macOS refused), and the real downloader against a local server (https only, a redirect to http, the size cap by header and by stream, the timeouts, 404 and 5xx); `test/tar_unpack_test.dart` unpacks hand-made archives and refuses a path with `..`, an absolute path, a symbolic or hard link, a device, a bomb, and a cut-off or corrupt tar. The CI job `zsign integration` installs the build tools, makes a throwaway CA, key, certificate and profile, and runs the real thing: `doctor --sign --build-zsign` downloads, checks and builds the pinned zsign and records the binary, `sign` starts the pinned zsign itself and signs an app that `tool/zsign_fixture.dart` generates, `sign --verify-only` and `upload --dry-run` check the result, and a changed zsign and a key open to other users are refused. `test/upload_test.dart` runs `upload` against a fake App Store Connect and a second fake for the upload store (the requests and their bodies, the parts rebuilding the IPA byte for byte, a part that fails and is sent again, a refused create that is not repeated, a failed processing, the timeout, each check that stops the run, `--dry-run` making no request, the confirmation, and that no token, key, link or signed header is ever printed), with an IPA that a throwaway key signed; `test/goldens/upload.txt` holds a redacted report. After a deliberate change, `UPDATE_GOLDENS=1 dart test` rewrites them; review the diff before committing. No test reaches the network.

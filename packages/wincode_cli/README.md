# wincode_cli

The `wincode` command. Its design is [ADR-0013](../../docs/adr/0013-wincode-cli-build-sign-upload.md).

Status: `doctor` and `preflight` work. The other commands are registered; each prints `not implemented yet, see ADR-0013` and exits with 64 until the phase of ADR-0013 that implements it.

```
dart run wincode_cli:wincode <command> [arguments]
```

| Command | What it will do | Phase |
| --- | --- | --- |
| `init` | Write `wincode.yaml` for the Flutter project in this folder | 2 |
| `preflight [<signed .ipa>]` | Check the signed IPA and App Store Connect before an upload. Read-only | works |
| `sign [<unsigned .ipa>]` | Sign the IPA for the App Store with zsign | 3 |
| `upload [<signed .ipa>]` | Upload the signed IPA to App Store Connect and wait for its processing | 4 |
| `status` | Show the state of the app's latest uploads in App Store Connect. Read-only | 4 |
| `build` | Build the unsigned IPA on the app's macOS runner (GitHub Actions) and download it | 5 |
| `doctor` | Check a Mach-O binary against the SDK or a reference build | works |

## Global options

They go before or after the command.

- `--config <file>`: the app's settings, `wincode.yaml` by default (below).
- `--json`: one JSON object on stdout when the command ends, with `command`, `ok`, `exitCode`, the results, and on a failure `error` with `id`, `what`, `why` and `next`. Messages go to stderr.
- `--redact`: hide the bundle ID and team ID in everything printed. It is always on when the `CI` environment variable is set (not empty, `0` or `false`). Commands register the IDs they learn with the redactor.
- `--verbose`: also print each step, external command and HTTP request, with secrets redacted.
- `--dry-run`: send, write and run nothing, and print what would be done.

`doctor`, `preflight` and the error output use `--json`. `--config`, `--dry-run` and the HTTP lines of `--verbose` are used by `preflight` so far; otherwise `--verbose` adds only the stack trace of an internal error.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Done |
| 1 | Failed: a check found a problem, an input is wrong, or Apple or GitHub refused the work |
| 64 | Usage error, or not implemented yet |
| 69 | A tool, the SDK or the network is missing |
| 70 | A bug in winCode |
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

`bundle_id` and `team_id` are required, and `output` defaults to `build/wincode`. Every value must be text. An unknown key is refused, and so is a key whose name looks like a secret; messages name the key, never its value. `loadConfig` reads and checks the file; `preflight` is the first command that reads it.

Secrets come only from environment variables, which name files outside the project: `WINCODE_ASC_KEY_DIR` (the App Store Connect key folder) and `WINCODE_DIST_KEY` (the distribution key on the WSL2 disk). `preflight` reads `WINCODE_ASC_KEY_DIR` (ADR-0013, section 2). A key or profile file inside a git working tree is refused unless git ignores it: `requireOutsideGit` does the check, and `preflight` calls it on each file of the key folder that it reads and on the profile, before reading them.

## preflight

```
dart run wincode_cli:wincode preflight [<signed .ipa>]
```

Read-only checks before an upload. In App Store Connect it sends GET requests only; it never creates, changes or uploads anything. Without an argument it checks `signed.ipa` in the `output` folder of `wincode.yaml`.

The API key comes from the folder that `WINCODE_ASC_KEY_DIR` names, outside every project and outside OneDrive: `AuthKey_<Key ID>.p8`, as App Store Connect delivered it, and a file `issuer-id` with the Issuer ID on one line. The token, the Key ID, the Issuer ID and the folder are never printed.

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
| `signature` | When the IPA holds `embedded.mobileprovision`: that profile passes the `local-profile` checks, and the executable is signed with the `application-identifier` `<team ID>.<bundle ID>`. An IPA without it is reported (INFO), not failed |

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
| 1 | `app-record-missing`, `build-number-not-higher`, `build-number-invalid`, `version-invalid`, `bundle-id-mismatch`, `app-id-missing`, `profile-missing`, `profile-expired`, `profile-team-mismatch`, `profile-not-app-store`, `profile-unreadable`, `ipa-missing`, `ipa-unreadable`, `signature-invalid`, `asc-error` |
| 69 | `offline`, `asc-unavailable`, `git-unavailable` |
| 77 | `asc-unauthorized` (HTTP 401), `asc-forbidden` (HTTP 403) |
| 78 | `config-missing`, `config-invalid`, `asc-key-dir-missing`, `asc-key-invalid`, `key-in-onedrive`, `key-in-git-tree` |

Requests time out after 20 seconds. One that gets no answer or HTTP 5xx is tried twice more, after 1 and 2 seconds. `HTTPS_PROXY` and `NO_PROXY` apply.

- `--dry-run` sends nothing and prints the GET requests in the form of `asc_preflight.py --dry-run`, with `{id of the app record}` and `{id of the App ID}` for the IDs that only Apple's answers would give. When `WINCODE_ASC_KEY_DIR` is set, it checks where the key lies and signs a token, which it does not show.
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

## doctor

```
dart run wincode_cli:wincode doctor --binary <Mach-O file> [--sdk <iPhoneOS.sdk folder>] [--reference <Mach-O file>]
```

- `--sdk` checks the binary against the text stubs of the SDK folder (`docs/formats/macho-conformance.md`) and fails on a library or binding that its minimum OS lacks. On Windows, the folder that `xtool sdk` built in WSL2 is read through `\\wsl.localhost\<distribution>\home\<user>\.swiftpm\swift-sdks\darwin.artifactbundle\Developer\Platforms\iPhoneOS.platform\Developer\SDKs\iPhoneOS.sdk`.
- `--reference` lists how the binary differs from a reference build, such as an Xcode-built copy: libraries, weak or strong, bindings and load commands. It does not fail.

It exits with 0 when the checks pass, 1 when one fails or a file cannot be read, 64 for a usage error, and 69 when `--sdk` names a folder that is not an SDK.

## The reference workflow

[`templates/wincode-ios.yml`](templates/wincode-ios.yml) is the workflow that `wincode build` will start in the app's repository (phase 5): it builds the unsigned IPA on a GitHub-hosted macOS runner and uploads it as the artifact `unsigned-ipa`. It has not been run yet.

## Tests

```
dart test
```

`test/goldens/help.txt` holds the `--help` output of every command. `test/goldens/preflight.txt` holds `preflight` reports and its `--dry-run` requests, and `test/goldens/preflight.json` its `--json` object, all from a fake App Store Connect on 127.0.0.1 with made-up IDs. After a deliberate change, `UPDATE_GOLDENS=1 dart test` rewrites them; review the diff before committing. No test reaches the network.

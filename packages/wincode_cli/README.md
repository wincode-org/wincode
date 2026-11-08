# wincode_cli

The `wincode` command. Its design is [ADR-0013](../../docs/adr/0013-wincode-cli-build-sign-upload.md).

Status: `doctor` works. The other commands are registered; each prints `not implemented yet, see ADR-0013` and exits with 64 until the phase of ADR-0013 that implements it.

```
dart run wincode_cli:wincode <command> [arguments]
```

| Command | What it will do | Phase |
| --- | --- | --- |
| `init` | Write `wincode.yaml` for the Flutter project in this folder | 2 |
| `preflight [<signed .ipa>]` | Check the signed IPA and App Store Connect before an upload. Read-only | 2 |
| `sign [<unsigned .ipa>]` | Sign the IPA for the App Store with zsign | 3 |
| `upload [<signed .ipa>]` | Upload the signed IPA to App Store Connect and wait for its processing | 4 |
| `status` | Show the state of the app's latest uploads in App Store Connect. Read-only | 4 |
| `build` | Build the unsigned IPA on the app's macOS runner (GitHub Actions) and download it | 5 |
| `doctor` | Check a Mach-O binary against the SDK or a reference build | works |

## Global options

They go before or after the command.

- `--config <file>`: the app's settings, `wincode.yaml` by default (below).
- `--json`: one JSON object on stdout when the command ends, with `command`, `ok`, `exitCode`, the results, and on a failure `error` with `id`, `what`, `why` and `next`. Messages go to stderr.
- `--redact`: hide the bundle ID and team ID in everything printed. It is always on when the `CI` environment variable is set (not empty, `0` or `false`). Commands register the IDs they learn with the redactor; none prints an ID yet.
- `--verbose`: also print each step, external command and HTTP request, with secrets redacted.
- `--dry-run`: send, write and run nothing, and print what would be done.

So far `doctor` and the error output use `--json`, and `--verbose` adds only the stack trace of an internal error. `--config` and `--dry-run` are for the commands of the later phases.

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

`bundle_id` and `team_id` are required, and `output` defaults to `build/wincode`. Every value must be text. An unknown key is refused, and so is a key whose name looks like a secret; messages name the key, never its value. `loadConfig` reads and checks the file; no command reads it yet.

Secrets come only from environment variables, which name files outside the project: `WINCODE_ASC_KEY_DIR` (the App Store Connect key folder) and `WINCODE_DIST_KEY` (the distribution key on the WSL2 disk). They are read from phase 2 on (ADR-0013, section 2). A key or profile file inside a git working tree is refused unless git ignores it: `requireOutsideGit` does the check, and no command calls it yet.

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

`test/goldens/help.txt` holds the `--help` output of every command. After a deliberate change, `UPDATE_GOLDENS=1 dart test test/cli_test.dart` rewrites it; review the diff before committing.

# workflows

GitHub Actions workflows.

| File | Purpose |
| --- | --- |
| `pr-title.yml` | Checks that the PR title follows Conventional Commits |
| `dco.yml` | DCO check: every commit in a PR must have a `Signed-off-by` line (no third-party actions) |
| `release-please.yml` | Opens release PRs and changelogs from Conventional Commits |
| `oracle-reference-builds.yml` | Manual macOS run: Xcode reference builds of the spike apps, text dumps of both bundles, and placeholder assets compiled by `actool` (an app icon, and the launch colour and image a `UILaunchScreen` entry names). No signing, no secrets; compare with `tools/ipa-diff` |
| `dart.yml` | On every pull request and every push to `main`: `dart format`, `dart analyze --fatal-infos` and `dart test` for `packages/wincode_core`, on Ubuntu with Dart 3.13.4 (the package pins the range `^3.13.0`) |

**macOS jobs never run for pull requests.** The jobs on a `macos-*` runner (`oracle-reference-builds.yml`, `gen-snapshot-oracle.yml`, `launch-events.yml`, `spike-a-oracle.yml`) start only on a push to their own branch or by hand (`workflow_dispatch`), and each job carries `if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'`. A new workflow that uses a macOS runner must do the same: the minutes are limited, and a pull request, from a fork or not, must not be able to spend them.

Build workflows will be added later.

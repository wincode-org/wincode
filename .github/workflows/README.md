# workflows

GitHub Actions workflows.

| File | Purpose |
| --- | --- |
| `pr-title.yml` | Checks that the PR title follows Conventional Commits |
| `dco.yml` | DCO check: every commit in a PR must have a `Signed-off-by` line (no third-party actions) |
| `release-please.yml` | Opens release PRs and changelogs from Conventional Commits |
| `oracle-reference-builds.yml` | Manual macOS run: Xcode reference builds of the spike apps, text dumps of both bundles, and placeholder assets compiled by `actool` (an app icon, and the launch colour and image a `UILaunchScreen` entry names). No signing, no secrets; compare with `tools/ipa-diff` |
| `dart.yml` | On every pull request and every push to `main`: `dart format`, `dart analyze --fatal-infos` and `dart test` for `packages/wincode_core`, on Ubuntu with Dart 3.13.4 (the package pins the range `^3.13.0`) |
| `hygiene.yml` | On every pull request and every push to `main`: `tools/scan-hygiene.sh` fails on a personal path, a key shape, a team-ID-shaped bundle ID, a certificate or profile file, and on names from a private list. It prints where, never what |

**The private list.** The names that must not be public (clients, apps, bundle-ID prefixes, local folder names, tool names) cannot be listed in this repository, because the list would name them. They live in the repository secret `HYGIENE_FORBIDDEN_TERMS`, a case-insensitive extended regular expression, read by `hygiene.yml`. Pull requests from forks cannot read secrets, so on them that rule is skipped and the log says so: before merging one, run `HYGIENE_FORBIDDEN_TERMS='…' tools/scan-hygiene.sh --base origin/main` locally. `tools/scan-hygiene.sh --history` checks the commit messages of every ref.

**macOS jobs never run for pull requests.** The jobs on a `macos-*` runner (`oracle-reference-builds.yml`, `gen-snapshot-oracle.yml`, `launch-events.yml`, `spike-a-oracle.yml`) start only on a push to their own branch or by hand (`workflow_dispatch`), and each job carries `if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'`. A new workflow that uses a macOS runner must do the same: the minutes are limited, and a pull request, from a fork or not, must not be able to spend them.

Build workflows will be added later.

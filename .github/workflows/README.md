# workflows

GitHub Actions workflows.

| File | Purpose |
| --- | --- |
| `pr-title.yml` | Checks that the PR title follows Conventional Commits |
| `dco.yml` | DCO check: every commit in a PR must have a `Signed-off-by` line (no third-party actions) |
| `release-please.yml` | Opens release PRs and changelogs from Conventional Commits |
| `oracle-reference-builds.yml` | Manual macOS run: Xcode reference builds of the spike apps, text dumps of both bundles, and placeholder assets compiled by `actool` (an app icon, and the launch colour and image a `UILaunchScreen` entry names). No signing, no secrets; compare with `tools/ipa-diff` |
| `dart.yml` | On every pull request and every push to `main`: `dart format`, `dart analyze --fatal-infos` and `dart test` for `packages/wincode_core`, on Ubuntu with Dart 3.13.4 (the package pins the range `^3.13.0`) |

Build workflows will be added later.

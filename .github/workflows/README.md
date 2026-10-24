# workflows

GitHub Actions workflows.

| File | Purpose |
| --- | --- |
| `pr-title.yml` | Checks that the PR title follows Conventional Commits |
| `dco.yml` | DCO check: every commit in a PR must have a `Signed-off-by` line (no third-party actions) |
| `release-please.yml` | Opens release PRs and changelogs from Conventional Commits |
| `oracle-reference-builds.yml` | Manual macOS run: Xcode reference builds of the spike apps, text dumps of both bundles, and placeholder assets compiled by `actool` (an app icon, and the launch colour and image a `UILaunchScreen` entry names). No signing, no secrets; compare with `tools/ipa-diff` |

Build and test workflows will be added later.

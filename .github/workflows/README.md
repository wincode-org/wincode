# workflows

GitHub Actions workflows.

| File | Purpose |
| --- | --- |
| `pr-title.yml` | Checks that the PR title follows Conventional Commits, with a few lines of shell under `pull_request` (no third-party action, no token, nothing checked out) |
| `dco.yml` | DCO check: every commit in a PR must have a `Signed-off-by` line (no third-party actions). Only release-please's commits are exempt: the Actions bot's exact email, in a PR that the bot opened |
| `release-please.yml` | Opens release PRs and changelogs from Conventional Commits (push to `main`; the only workflow with write permissions) |
| `oracle-reference-builds.yml` | Manual macOS run: Xcode reference builds of the spike apps, text dumps of both bundles, and placeholder assets compiled by `actool` (an app icon, and the launch colour and image a `UILaunchScreen` entry names). No signing, no secrets; compare with `tools/ipa-diff` |
| `dart.yml` | On every pull request and every push to `main`: `dart format`, `dart analyze --fatal-infos` and `dart test` for `packages/wincode_core`, `packages/wincode_asc` and `packages/wincode_cli` (a matrix with one job per package) on Ubuntu, and for `packages/wincode_cli` on Windows too, with Dart 3.13.4 (the packages pin the range `^3.13.0`). The Ubuntu jobs keep the names that branch protection requires |
| `hygiene.yml` | On every pull request and every push to `main`: `tools/scan-hygiene.sh` fails on a personal path, a key shape, a team-ID-shaped bundle ID, a certificate, profile, IPA or Xcode archive file, and on names from a private list. It prints where, never what |

**The private list.** The names that must not be public (clients, apps, bundle-ID prefixes, local folder names, tool names) cannot be listed in this repository, because the list would name them. They live in the repository secret `HYGIENE_FORBIDDEN_TERMS`, a case-insensitive extended regular expression, read by `hygiene.yml`. The rule **fails closed**: if the secret is empty, the job fails (rule `terms-missing`), so a deleted or renamed secret cannot turn the check green. The only exception is a pull request from a fork, which cannot read secrets: `hygiene.yml` sets `HYGIENE_FORK_PR=true` there, the rule is skipped with a warning annotation, and before merging such a PR a maintainer runs `HYGIENE_FORBIDDEN_TERMS='…' tools/scan-hygiene.sh --base origin/main` locally. Dependabot PRs read Dependabot secrets, not Actions secrets, so the same secret must also be added under Dependabot or its PRs fail. `tools/scan-hygiene.sh --history` checks the commit messages of every ref.

**macOS jobs never run for pull requests.** The jobs on a `macos-*` runner (`oracle-reference-builds.yml`, `gen-snapshot-oracle.yml`, `launch-events.yml`, `spike-a-oracle.yml`) start only by hand (`workflow_dispatch`), and each job carries `if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'`. A new workflow that uses a macOS runner must do the same: the minutes are limited, and a pull request, from a fork or not, must not be able to spend them.

**Artifacts of Apple tools are never public.** In a public repository anyone can download a run's artifacts. Every `upload-artifact` step in those four workflows therefore has `github.event.repository.private == true` in its `if:` and keeps its files for 1 day: in a public repository the job runs but uploads nothing, so run it from a private repository to keep the files.

**Pinned actions.** Every third-party action is pinned to a full commit SHA with its version in a trailing comment, and every `actions/checkout` that does not push sets `persist-credentials: false`. `release-please.yml` is the only workflow with write permissions (`contents` and `pull-requests`).

Build workflows will be added later.

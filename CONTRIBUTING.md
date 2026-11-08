# Contributing to winCode

Thanks for helping. winCode is pre-alpha, so expect things to move.

## Workflow

- Every change goes through a branch and a pull request, including the maintainer's. Nobody pushes to `main`.
- Keep PRs small and focused. One concern per PR.
- Fill in the PR template, including test evidence and, for device-related changes, the device and iOS version.
- CI must be green and `main` keeps a linear history: pull requests are squash-merged, one commit per PR.

## Commits and PR titles

We use [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`, for example `feat(cli): add build ipa command`. Common types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`. The PR title is checked in CI and is used as the squash commit message, so it must follow the same format. Releases are generated from these messages by release-please.

## DCO sign-off

Every commit must be signed off to certify the [Developer Certificate of Origin](https://developercertificate.org/):

```
git commit -s -m "feat(cli): ..."
```

This adds a `Signed-off-by: Your Name <you@example.com>` line. Use your real name.

The **DCO** check (`.github/workflows/dco.yml`) fails a PR if any commit in it lacks that line. To fix it:

```
git commit --amend -s --no-edit      # only the last commit is unsigned
git rebase --signoff origin/main     # several commits are unsigned
git push --force-with-lease          # then force-push your branch
```

## Hygiene check

The **names, paths and keys** check (`.github/workflows/hygiene.yml`, `tools/scan-hygiene.sh`) fails a PR that adds a personal path, a key, a team-ID-shaped bundle ID, a certificate, a provisioning profile, an IPA, an Xcode archive, a `.dSYM` bundle or a `Payload/` folder. It also checks names that must not be public. That list is a repository secret, because the list itself would name them, and the check prints where a problem is, never what it found.

- **Your PR comes from a fork:** GitHub gives forks no secrets, so the name rule cannot run and is skipped with a warning. A maintainer runs it before merging. You can run the other rules yourself: `HYGIENE_FORK_PR=true tools/scan-hygiene.sh --base origin/main`.
- **Any other run** (a push to `main`, a branch in this repository) **fails if the list is empty**, so a deleted or renamed secret cannot turn the check green. The same applies to Dependabot PRs, which read Dependabot secrets, not Actions secrets: the secret must be set in both places.

## Releases

[release-please](https://github.com/googleapis/release-please) opens the release PR from Conventional Commits. That PR is opened with the default `GITHUB_TOKEN`, and GitHub does not start the usual checks for it: its workflow runs stay in `action_required` with no jobs, so the required checks never report and the PR stays blocked. The fix (a token for release-please that is not the default one) has not been chosen yet; this section will say which when it is.

## Clean-room rule for Apple file formats

Some parts of winCode (for example the `Assets.car` compiler) must produce Apple file formats that Apple does not document. To keep the project legally clean:

1. **Spec first.** Observe outputs (files produced by real Xcode on Apple hardware, public documentation, open-source tools) and write the format spec in `docs/formats/` before any implementation.
2. **Implement from the spec only.** The person writing the implementation works from the spec, not from Apple software.
3. **Never decompile or disassemble Apple tools or frameworks** (`actool`, `ibtool`, CoreUI, Xcode itself). Inspecting file formats and outputs is fine; reverse engineering Apple's software is not.
4. **Record provenance.** The PR template has a checkbox for "touches Apple formats"; if ticked, say where each fact in the spec came from.

## Never commit

Xcode or Apple SDK files, `.xip` archives, certificates, `.p8`, `.p12`, `.mobileprovision` files, built apps (`.ipa`, `.xcarchive`, `.dSYM`, `Payload/`), or any credentials. See `.gitignore`; the hygiene check fails on them.

## Decisions

Significant design decisions are written up as ADRs in `docs/adr/` (copy `0000-template.md`).

## Conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

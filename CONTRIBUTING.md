# Contributing to winCode

Thanks for helping. winCode is pre-alpha, so expect things to move.

## Workflow

- Every change goes through a branch and a pull request, including the maintainer's. Nobody pushes to `main`.
- Keep PRs small and focused. One concern per PR.
- Fill in the PR template, including test evidence and, for device-related changes, the device and iOS version.
- CI must be green and `main` keeps a linear history.

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

## Clean-room rule for Apple file formats

Some parts of winCode (for example the `Assets.car` compiler) must produce Apple file formats that Apple does not document. To keep the project legally clean:

1. **Spec first.** Observe outputs (files produced by real Xcode on Apple hardware, public documentation, open-source tools) and write the format spec in `docs/formats/` before any implementation.
2. **Implement from the spec only.** The person writing the implementation works from the spec, not from Apple software.
3. **Never decompile or disassemble Apple tools or frameworks** (`actool`, `ibtool`, CoreUI, Xcode itself). Inspecting file formats and outputs is fine; reverse engineering Apple's software is not.
4. **Record provenance.** The PR template has a checkbox for "touches Apple formats"; if ticked, say where each fact in the spec came from.

## Never commit

Xcode or Apple SDK files, `.xip` archives, certificates, `.p8`, `.p12`, `.mobileprovision` files, or any credentials. See `.gitignore`.

## Decisions

Significant design decisions are written up as ADRs in `docs/adr/` (copy `0000-template.md`).

## Conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

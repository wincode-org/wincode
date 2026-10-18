# 0007. Keep a copy of xtool's source in third_party/xtool

- Status: Accepted
- Date: 2026-10-17

## Context

ADR-0006 keeps all of winCode's code in this repository and uses xtool as an external tool, through its official releases. The maintainer asked for xtool's source to be copied into winCode too, so the project owns a copy it can read, review and, when needed, change.

xtool is MIT-licensed. The teardown in `docs/xtool/` documents how it works and lists the licences of its dependencies.

## Decision

- **Keep an exact copy** of xtool 1.22.2 (tag commit `65bf3cc`) in `third_party/xtool/`.
  - It contains every file upstream tracks, byte-identical, with file modes and symlinks.
  - It leaves out xtool's instructions for coding agents and three tutorial screenshots.
- **Keep xtool's `LICENSE.md` unchanged.** `third_party/README.md` records the source, version, exclusions and every local patch.
- **winCode still runs xtool's official release binary in v1** (ADR-0006). The copy is for reading, review and future patches.
- **Building and shipping our own xtool binary is a separate decision.** That's when the LGPL obligations of `xadi`, `unxip` and the libimobiledevice libraries apply.
- **On each xtool upgrade:** replace the tree with the new tag, check every blob hash against upstream, and re-apply the recorded patches (`third_party/README.md`).

## Consequences

- The repository grows by about 4 MB, and xtool's fixes reach the copy only when someone updates it.
- winCode can patch xtool without waiting for upstream. Candidates: launch on recent iOS, streaming the upload instead of reading the whole `.ipa`, and storing secrets more safely.
- The copy and the binary in use can drift. `third_party/README.md` states which release binary winCode runs.

## Alternatives considered

- **A git submodule pointing at xtool or a fork:** keeps the history, but the code lives outside winCode (against ADR-0006) and complicates cloning.
- **`git subtree` with full history:** much larger, and the history isn't needed.
- **No copy** (ADR-0006 alone): simpler, but the maintainer wants the code in the repository.

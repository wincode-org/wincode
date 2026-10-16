# 0006. Keep all of winCode's code in the winCode repository

- Status: Accepted
- Date: 2026-10-16

## Context

`docs/PLAN.md` said that anything winCode builds that isn't Flutter-specific would go upstream to xtool as a pull request: the `Assets.car` compiler, the LLDB integration and the App Store upload. That would split winCode's work across two projects, and parts of it would depend on another project's review and release cycle. The maintainer decided that winCode keeps everything.

## Decision

- **All of winCode's code lives in `wincode-org/wincode`,** whether or not it is Flutter-specific. winCode does not send changes upstream to xtool.
- **winCode keeps using xtool as an external tool,** through its official releases (1.22.2 or later). It is used for the Darwin SDK, Apple account login, provisioning, signing and install (ADR-0001, ADR-0005).
- **The `../xtool` reference clone stays read-only.**

## Consequences

- One repository, one licence and one release cycle. Nothing waits on another project's review.
- winCode alone builds and maintains the `Assets.car` compiler, the LLDB integration and the App Store upload.
- winCode still gets xtool's fixes by upgrading to new releases; the `-80045` login fix arrived that way.
- When winCode needs a change inside xtool itself, the options are a workaround in winCode, or revisiting this decision, for example by vendoring xtool's MIT-licensed source.

## Alternatives considered

- **Send non-Flutter pieces upstream to xtool** (the original plan): shared maintenance and wider reach, but the work is split across two projects.
- **Vendor xtool's source into winCode:** full control, but winCode would have to merge xtool's upstream fixes by hand.

# Governance

## Current state

winCode has a single maintainer, [@AlphaaCode](https://github.com/AlphaaCode). The maintainer has final say on scope, releases and merges. Decisions of lasting consequence are recorded as ADRs in `docs/adr/` so the reasoning stays public.

## Becoming a co-maintainer

The goal is two co-maintainers by v0.1. A contributor can be invited when they have:

- a sustained record of merged, high-quality PRs (roughly 10 or more over at least 2 months),
- reviewed other people's PRs constructively,
- shown they understand and follow the clean-room rule for Apple formats and the no-SDK-redistribution rule.

The maintainer invites them (or a contributor can ask in a GitHub Discussion, once Discussions are enabled at launch). Co-maintainers get write access and are added to `CODEOWNERS`. Maintainers may step down at any time, and inactive maintainers (about 6 months) can be moved to emeritus.

## Decisions

Day-to-day: with a single maintainer, the maintainer may merge their own PRs once CI is green. A PR from anyone else needs one maintainer's approval as well as green CI. Larger changes: open an ADR PR and allow at least a week for comment. Once there is more than one maintainer, decisions are by consensus, falling back to a simple majority of maintainers.

## Code of Conduct

Enforced per [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

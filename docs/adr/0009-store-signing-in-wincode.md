# 0009. winCode owns store signing and never revokes certificates on its own

- Status: Proposed
- Date: 2026-10-18

## Context

- **xtool covers development only.** It makes development certificates and profiles, re-creates the App ID's development profile on every install with every device on the team, and rewrites bundle IDs to `XTL-<prefix>.<id>` (`docs/xtool/README.md`). That is fine for development and wrong for the store.
- **A distribution certificate belongs to the whole team.** Revoking it, or deleting a profile another tool made, can break other people's releases.
- **Tools revoke on their own.** xcross, a candidate for hot reload, revokes every certificate on the team without asking when a certificate request hits Apple's limit (HTTP 409) or when its cached certificate has gone from the team (`docs/PLAN.md`, "xcross review"). xtool can ask to revoke certificates on a free team (`docs/xtool/plan.md`, section 2).

## Decision

- **winCode makes store signing itself** through the App Store Connect API: the CSR, an Apple Distribution certificate, the App ID with the capabilities the entitlements need, and an App Store profile. It signs with zsign: production entitlements, no `get-task-allow`, every nested binary.
- **Store builds never go through xtool provisioning.** Development signing and install stay with xtool (ADR-0006).
- **winCode never revokes or replaces a certificate, and never deletes a profile it did not create, on its own.** It lists what it would change and asks first. It never revokes or replaces a team's existing distribution certificate; if a new one is needed, the account holder or an Admin creates it.
- **Secrets stay in Windows Credential Manager:** the App Store Connect key (`.p8`) and the distribution private key, passed per call.
- **No tool that revokes on its own gets a real team's key.** xcross runs only with a throwaway free Apple ID.

## Consequences

- winCode needs its own App Store Connect client (`packages/wincode_asc`), built from Apple's published OpenAPI schema (`docs/xtool/plan.md`, section 4).
- On a shared team, the user may have to ask an Admin to create the distribution certificate; winCode says exactly what is needed.
- Store signing works the same in both release lanes (ADR-0008).

## Alternatives considered

- **Extend xtool's provisioning to distribution:** it would mean changing xtool (ADR-0006 keeps winCode's code in winCode), and its development rules (profile churn, bundle ID rewrite) are wrong for the store.
- **The user creates everything at developer.apple.com and imports a `.p12`:** stays as a fallback for teams where only an Admin can create certificates, but it is too manual as the default.
- **Let xcross sign:** it revokes certificates on its own.

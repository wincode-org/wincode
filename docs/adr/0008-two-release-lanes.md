# 0008. Two release lanes: pure Windows and cloud Mac

- Status: Proposed
- Date: 2026-10-18

## Context

winCode can build and sign an IPA on Windows, but two things are unproven for store builds:

- **Acceptance:** nobody has shown yet that App Store Connect accepts an IPA built without Xcode. Spike C tests it (`docs/PLAN.md`, "Spike C").
- **Licence:** the Xcode and Apple SDKs Agreement allows the SDK only on Apple-branded computers. Building with it on a PC, as xtool does, may put the developer account at risk (`docs/PLAN.md`, "Licence and account risk").

Until both are settled, shipping must not depend on the pure-Windows path alone.

## Decision

- **Two lanes, one command.** `wincode ship` builds on the user's PC with winCode's toolchain in WSL2. `wincode ship --lane mac` builds with Xcode (`flutter build ipa`) on a hosted macOS runner in the user's own GitHub repository.
- **Both lanes upload the same way:** Transporter for Windows or the App Store Connect Build Uploads API, with the user's API key.
- **Cloud Mac is the default for store builds** until spike C passes and the licence review is done. The pure-Windows lane stays available and becomes the default only after both.
- **Development builds stay on the PC** (`wincode install`, `wincode run`) in either case.

## Consequences

- Shipping never waits on spike C, the `Assets.car` compiler or the legal review.
- winCode generates and maintains a GitHub Actions workflow for the Mac lane, and the user needs a GitHub repository. Hosted macOS runners are free on public repositories (standard runners) and cost minutes on private ones.
- The Mac lane also builds the reference IPA that spike C and the zero-rejection checks compare against.
- If spike C finds a toolchain rejection that honest metadata cannot fix, the cloud Mac lane becomes the store lane for good.

## Alternatives considered

- **Pure Windows only:** the goal, but every release would wait on spike C, `Assets.car` and the legal review.
- **Cloud Mac only:** safe, but it gives up winCode's main promise and always needs a GitHub repository and runner minutes.
- **A rented remote Mac:** works, but it costs money and leaves the user another machine to manage.

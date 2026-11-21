# third_party

Upstream source code kept in this repository (ADR-0007). Each entry keeps its own licence file. Local changes are allowed only as patches listed here.

## xtool

| Item | Value |
| --- | --- |
| Upstream | https://github.com/xtool-org/xtool |
| Version | 1.22.2, tag commit `65bf3cc5a1240fea53ac0748d29a01878222a6ce` |
| Licence | MIT, `xtool/LICENSE.md` (Copyright (c) 2024 Kabir Oberai), unchanged |
| Copied | Every file upstream tracks at that commit, byte-identical, including file modes and one symlink (verified against upstream's git index, 260 entries) |
| Left out | xtool's instruction files for coding agents (they would mix into winCode's), and three tutorial screenshots in `Documentation/xtool.docc/Resources/` (`Cover.png`, `Home.png`, `UntrustedDev.png`, 8.6 MB) |
| Local patches | None |
| Binary used by winCode | The official xtool 1.22.2 release AppImage, not a build of this copy (ADR-0006) |

Dependencies are not copied; SwiftPM fetches them from `Package.resolved`. Most are MIT or Apache-2.0.

`xadi` (LGPL-2.1), `unxip` (LGPL-3.0) and the libimobiledevice libraries (LGPL-2.1) matter only if winCode builds and ships its own xtool binary. That needs a separate decision covering licence texts, a source offer and replaceable shared libraries. How xtool works is documented in `docs/xtool/`.

### Updating to a new xtool release

1. Clone the new tag into a scratch directory outside the repo.
2. Replace `xtool/` with every file `git ls-files` lists at that tag, minus the files left out above.
3. Stage exactly that list with `git add -f`, because winCode's `.gitignore` would otherwise drop files such as `.vscode/` and `macOS/XToolMac.xcodeproj/`. Record symlinks as mode 120000 and keep executable bits.
4. Check that every mode and blob hash matches the new tag's `git ls-files -s`.
5. Re-apply the patches listed above, update this table, and note the change in the pull request.

## stripe-ios-spm (not copied here; patched in the scratch checkout of a build)

No file of it is in this repository. An app that uses the Stripe iOS SDK through Flutter's `stripe_ios` plugin resolves `stripe-ios-spm` through SwiftPM, and winCode builds it from source. One local change is needed until the Darwin SDK's macro server knows the preview macros (ADR-0012).

| Item | Value |
| --- | --- |
| Upstream | https://github.com/stripe/stripe-ios-spm, version 26.3.0, commit `03d261e01eb65d6ff17b90614179e885cb0316f0` |
| Licence | MIT (Copyright (c) 2011- Stripe, Inc.), unchanged in the checkout |
| Patch | In the `StripePaymentSheet` target, remove the four `#Preview` blocks, each together with the `@available` line directly above it: 74 lines deleted, none added |
| Where | Under `StripePaymentSheet/StripePaymentSheet/Source/`: `Internal/Link/Components/Hint/LinkHintMessageView.swift` lines 179-204, and in `PaymentSheet/WalletButtonsView/`: `LinkButton.swift` lines 151-169, `LinkProgressIndicatorView.swift` lines 41-44, `LinkInlineVerificationView.swift` lines 212-236 |
| Check | SHA-256 of the unified diff (`git diff` in the checkout, 109 lines): `5cfd56da879e69a352e8478d62c85abda1442253ec04384275242331e8fc77e3` |
| Why it is safe | A preview leaves nothing in a release binary: neither Xcode's `Runner` nor winCode's contains `PreviewRegistry` or `PreviewsMacros`. Two of the four blocks sit inside `#if DEBUG` and are not compiled in a release build at all |
| Proven | A build with this patch was processed as valid by App Store Connect and ran on an iPhone: launch, the payment sheet, Google and Apple sign-in |
| How it is applied | By hand, to the scratch checkout that SwiftPM makes for the build. No tool applies it yet |
| Not used | OpenAppleMacros 1.4.1 compiles the unpatched sources (tested in a scratch folder). Adopting it means changing the pin in xtool's SDK builder, which needs its own decision and a patch recorded for `xtool` above |

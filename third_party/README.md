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

# engine

Build scripts that produce `gen_snapshot` for iOS arm64 on a Linux host, per Flutter release (ADR-0004).

Flutter ships `gen_snapshot` for iOS only as a macOS program. winCode builds its own from the standalone Dart SDK at the revision that the Flutter release pins in its `DEPS` file, with a Linux x64 host and `target_os = "ios"`. The tool and the kernel it reads must come from the same Dart revision: the kernel carries the first ten characters of that revision, and the tool refuses a kernel with another.

| File | What it does |
| --- | --- |
| `sync.sh <Flutter SDK folder>` | Reads `dart_revision` from the SDK's `DEPS`, clones depot_tools from `chromium.googlesource.com` and syncs the Dart SDK from `dart.googlesource.com` at that revision |
| `build.sh <Flutter SDK folder>` | Applies the three GN edits of ADR-0004 (each anchored: the script stops if Dart changes those lines), writes `args.gn` with the revision's hash, builds only `gen_snapshot`, and installs it |
| `args.gn` | The GN arguments: a real `target_os = "ios"` product build with the arguments the Flutter engine uses |

The tool is installed in `$WINCODE_HOME/engines/<engine version>/gen_snapshot` (`WINCODE_HOME` defaults to `~/.wincode`), with `info.txt` beside it. `build.sh` checks that the tool's Dart version is the one the Flutter SDK ships (`bin/cache/dart-sdk/version`). `DEPOT_TOOLS` names an existing depot_tools checkout to reuse.

## Measured

Flutter 3.47.5 (engine `af7e796e16`, Dart 3.13.4, revision `b530c21f7de3...`), on a 12-core PC under WSL2:

| Step | Time | Disk |
| --- | --- | --- |
| `sync.sh` | 294 s | 5.6 GB for the Dart checkout, 0.9 GB for depot_tools |
| `build.sh` | 175 s | 5.9 GB in all (checkout and build); the tool is 87 MB |

## Not here yet

- The second check of ADR-0004 (the official macOS `gen_snapshot` run on the same kernel with a glibc-style `qsort`, for a byte-identical `App`) and the CI job that publishes the tool for each release.
- Windows and macOS hosts.

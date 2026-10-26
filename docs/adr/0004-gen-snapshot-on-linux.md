# 0004. Build the iOS gen_snapshot on Linux from the Dart SDK

- Status: Accepted
- Date: 2026-10-16

## Context

Flutter ships `gen_snapshot` for iOS only as a macOS executable: `ios-release/gen_snapshot_arm64` is a universal x86_64 + arm64 Mach-O. Without an equivalent on a non-Mac host, winCode cannot produce the release `App.framework` on Windows. `docs/PLAN.md` made this the first kill switch.

Spike A (`docs/spikes/spike-a-gen-snapshot.md`) found:

- **The target OS is chosen at compile time.** GN `target_os = "ios"` defines `DART_TARGET_OS_MACOS_IOS`. Nothing in the code generator needs macOS.
- **There is no assembly or `clang` step.** At Flutter 3.47.7, flutter_tools runs `gen_snapshot --snapshot_kind=app-aot-macho-dylib`, so gen_snapshot writes the Mach-O `App.framework/App` itself.
- **It builds on Linux with GN changes only.**
  - Source: the standalone Dart SDK at the release's `dart_revision`.
  - Configuration: a real `target_os = "ios"` build on Linux x64.
  - Changes: three GN-only edits, no C++ changes.
  - Cost: sync 168 s, build 133 s, +7.3 GB.
- **The output matches the official one.**
  - It carries the snapshot hash and the full features string of the pinned `Flutter.framework`.
  - It is byte-identical to the official macOS gen_snapshot's `App` when both use the same `qsort` tie-breaking. Without that, only the code and data layout differ.

Spike B (`docs/spikes/spike-b-device.md`) then ran that `App.framework` with the prebuilt `Flutter.framework` on an iPhone 15 with iOS 27.0.1.

## Decision

1. **Build per release.** For each supported Flutter release, winCode builds an iOS arm64 `gen_snapshot` that runs on Linux x64:
   - from the standalone Dart SDK at the `dart_revision` that the release's `DEPS` pins;
   - with the GN changes and `args.gn` in `spikes/a-gen-snapshot/`: `target_os = "ios"`, product mode, and the Dart args the Flutter engine uses, such as `dart_use_compressed_pointers = false` and `dart_sdk_verification_hash`.
2. **CI publishes it, users don't build it.** winCode CI builds and publishes it per release (`engine/`), and users download it.
3. **winCode calls it the way flutter_tools does** for iOS release builds:
   - `--snapshot_kind=app-aot-macho-dylib` and the same `--macho*` flags;
   - then `dsymutil` and a `strip -x` equivalent.
4. **Each published gen_snapshot must pass two checks before release:**
   - Its snapshot hash and features string match that release's `Flutter.framework`.
   - On a macOS runner, the official `gen_snapshot_arm64` run on the same `app.dill` with a glibc-style `qsort` gives a byte-identical `App`. `.github/workflows/spike-a-oracle.yml` shows how.

## Consequences

- The kill switch "`gen_snapshot` for iOS can't be built for a non-Mac host" is retired.
- **Per-release cost:**
  - one sync: about 3 minutes, with a cache of about 6.5 GB;
  - one build: 2–3 minutes on 12 cores;
  - one short macOS run. That is cheap enough to cover stable and beta.
- **The GN changes are anchored string edits** in Dart's `build/config/BUILDCONFIG.gn` and `build/config/compiler/BUILD.gn`. `build.sh` stops with an error when Dart changes those lines, and the edits then have to be refreshed.
- **winCode's `App` binaries differ in layout from a Mac build of the same app.**
  - Dart's dispatch-table sort uses the host's `qsort`, and macOS libc and glibc break ties differently. Both outputs are valid.
  - Byte-identical output would need a host-independent sort in Dart's `--deterministic` mode, which winCode can propose upstream.
- **No Apple software is used** to build or run gen_snapshot (Dart SDK, BSD licence). The Darwin SDK is only needed for the runner.
- **The app must embed `App.framework` without linking it.**
  - Dart's Mach-O dylib has no exports trie, so `ld64.lld` refuses to link it.
  - The engine finds and loads it at runtime (spike B).
- A Windows-host gen_snapshot remains possible later. Linux in WSL2 is enough for v1 (ADR-0001).

## Evidence

Check 2 of the decision, run for Flutter 3.47.5 (`.github/workflows/gen-snapshot-oracle.yml`, run 40328202302, 2026-10-26, `macos-26`: macOS 26.6.2 on arm64, Xcode 26.6). The sample is the stock counter app, so no client code is in the workflow. Its kernel is made on the runner by `flutter assemble kernel_snapshot_program` for iOS release (23,201,752 bytes, SHA-256 `868a321d…4c9d`). The official `gen_snapshot_arm64` of Flutter's artifacts (Dart 3.13.4) runs on it with the arguments flutter_tools uses. winCode's tool, built by `engine/` from the Dart revision that 3.47.5 pins (`b530c21f…`), runs on the same kernel under WSL2 (glibc 2.39).

| Run | `App.framework/App` (4,362,672 bytes) | SHA-256 |
| --- | --- | --- |
| (a) official, as it is | reference | `d0821148…9072` |
| (c) official, thin ad-hoc re-signed copy (control) | byte-identical to (a) | `d0821148…9072` |
| (b) official copy with `qsort` replaced by a stable merge sort with glibc's tie-breaking, through `DYLD_INSERT_LIBRARIES` (45,432 calls) | differs from (a) in 3,268,259 bytes (74.9%), same size | `12212f79…2339` |
| winCode's `gen_snapshot` on Linux | **byte-identical to (b)**, differs from (a) like (b) does | `12212f79…2339` |

- **The interposition works.** The official tool is copied, thinned and re-signed ad hoc without the hardened runtime, so that macOS keeps `DYLD_INSERT_LIBRARIES`. The control (c) shows that the copy behaves like the original, and the run stops if the interposer logs no calls. It logged 45,432, the same number as spike A's run on Flutter 3.47.7, and (b) has the same digest as spike A's.
- **The only host difference is the `qsort` tie-breaking.** With the same sort the official tool and winCode's give the same `App`, byte for byte. With macOS's own sort the layout differs.
- **`app.o` differs, and is not shipped.** Its code and data sections are identical to (b)'s; only `__DWARF,__debug_info` differs, because the producer string names the host (`linux_simarm64` or `macos_arm64`) and shifts the offsets.
- **Not proven for a real app.** The proof uses a small stock app. For a larger production app built outside this repository, the Mach-O layout, the two symbols and their addresses were the same, and 13.4% of the code and data bytes were identical at the same position, as expected without the Mac's `qsort`. Running the official tool on a real app's kernel would put that app's code into a workflow, so it is not done.

## Alternatives considered

- **Build inside the Flutter engine tree:** a 20–30+ GB checkout and more GN patches. The engine's iOS toolchains assert a Mac host, and `tools/gn` expects Apple SDKs.
- **Run the official macOS gen_snapshot under emulation (Darling):** untested on WSL2, and a heavy dependency.
- **Emit assembly and assemble it with `clang`:** obsolete. flutter_tools no longer does this for iOS, and the Mach-O writer already produces the dylib.
- **Build every app on a remote Mac or macOS CI:** defeats the purpose of winCode. It stays only as the optional Mac release lane and as the oracle.
- **Patch Dart's C++ to make the output byte-identical to Mac builds:** not needed for correctness. Propose it upstream instead.

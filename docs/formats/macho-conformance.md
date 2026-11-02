# Mach-O conformance check: design

Status: design, 2026-11-02. It is step 3 of the next steps in `docs/PLAN.md`: a post-link check that no library or binding in the runner is newer than the app's minimum OS, beyond the `SwiftUICore` case of ADR-0012.

The check reads an iOS binary and the user's own SDK, and fails on a violation. `buildRunner` runs it after linking (in place of today's `SwiftUICore`-only check) and `wincode doctor` runs it on a given binary.

## What it reads from the binary

- The load commands: each dylib load with its kind (strong, weak, re-export, upward, lazy) and install name, the rpaths, `LC_BUILD_VERSION` (platform, minimum OS, SDK) and the kinds of all commands, for the diff.
- The import table of `LC_DYLD_CHAINED_FIXUPS`, in its three formats: for each import, the symbol name, the weak bit and the library ordinal, which names the library the symbol is bound to. A binary that binds with opcodes instead (older links), or has compressed names, is reported as not checkable, which fails.

## What it reads from the SDK

Only the text stubs (`.tbd`, TBD version 4, one or more YAML documents per file) of the libraries the binary loads from the system, found by install name under the SDK folder and under `System/Cryptexes/OS`. From each document: `install-name`, whether it has `allowable-clients`, and four linker directives written as exported names:

| In the stub of library L | Meaning | Violation |
| --- | --- | --- |
| `$ld$previous$<P>$<compat>$<platform>$<start>$<end>$<S>$` | for a minimum OS in [start, end) on that platform, S is in P, not in L | S is bound to L; it needs `end` |
| the same with an empty S | for such a minimum, L itself is named P | L is loaded; it needs `end` |
| `$ld$install_name$os<v>$<P>` | at a minimum of exactly v, L is named P | L is loaded |
| `$ld$hide$os<v>$<S>` or `$ld$hide$<S>` | at a minimum of exactly v (or always), L does not export S | S is bound to L |
| `allowable-clients` | only the listed clients may link L; an app reaches its symbols through the library that re-exports it | L is loaded, weak or strong, at any minimum |

Each report names the library or symbol, the OS it needs and the app's minimum. For a restricted library the OS shown is the earliest `end` among its own moved-symbol directives that covers the minimum, when there is one. A system library with no stub in the SDK is a violation too: the check cannot vouch for it. Libraries under `@rpath`, `@executable_path` or `@loader_path` ship in the app and are not checked against the SDK.

## What the SDK says about `SwiftUICore` (iPhoneOS 26.5)

Its stub restricts its clients (an app is not one of them), and `SwiftUI` re-exports it. 14,750 of its symbols carry "in `SwiftUI` before iOS 18.0" (a few 18.1, 18.2 or 26.0). No directive says that the library itself starts at iOS 18. The two symbols that the first winCode build of the real app bound to it (ADR-0012, item 4) are protocol witness tables with no directive, so only the `allowable-clients` rule catches that runner; a per-symbol rule alone would pass it. Xcode's runner binds both to `SwiftUI`.

## Not covered

- A framework that is new but neither moved, renamed nor restricted, loaded strongly below its first OS. Stubs have no first-OS mark. The compiler weak-links references to APIs newer than the minimum, from the annotations in headers and Swift interfaces, and the check trusts those weak bits. See the decision below.
- A symbol bound to a library that re-exports others is looked up in that library's stub only.
- `$ld$add$` (it only adds symbols), and binaries with `LC_VERSION_MIN_IPHONEOS` instead of `LC_BUILD_VERSION`.

## Diff mode

Ours against a reference (an Xcode-built copy): libraries and their kind, rpaths, minimum OS and SDK, the bindings to each library (counts, and the names found in one binary only) and the kinds of load commands found in one only. It reports and does not fail: some differences are expected (`lld` is not `ld`, ADR-0012).

## Clean-room limits

- The SDK is read at run time from the user's own copy, which `xtool sdk` builds from their Xcode.xip. Nothing from it is committed: no stub, excerpt, symbol list or table derived from it. The counts above are observations, as in ADR-0012.
- The formats come from public open-source references: LLVM's `llvm/BinaryFormat/MachO.h` (load commands, chained fixups), LLVM's TextAPI (TBD version 4) and `lld/MachO/InputFiles.cpp` (the `$ld$` directives and allowable clients). No Apple tool or framework is decompiled or disassembled. What Xcode does is taken from its output, the reference runner.
- Tests build their Mach-O files in code and use hand-written stubs with invented symbol names. The install names of public frameworks (`SwiftUI`, `SwiftUICore`) appear as names only. No app, client, bundle ID or local path appears.

## Pull requests

Each is a draft from `main`; one that needs another is opened after that one is merged. 1. This note. 2. The Mach-O reader. 3. The SDK stub reader. 4. The check, with `buildRunner` failing on a violation. 5. The diff. 6. `wincode doctor` in `packages/wincode_cli`.

## Decision for the maintainer

New frameworks (first item under "Not covered"): stubs only, which is exact (recommended), or stubs plus a first-OS estimate per framework, the lowest iOS version among the annotations in its headers and Swift interfaces. The second covers more, but it is a heuristic that can fail a good build, and it is more code.

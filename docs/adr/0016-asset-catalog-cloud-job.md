# 0016. A cloud job compiles asset catalogs with `actool` (D1)

- Status: Proposed
- Date: 2026-11-21

Design only. Nothing here has been built or run, and no macOS minute has been spent for it. Every macOS run of this design needs the maintainer's word RUN.

## Context

In the measured app (`docs/producer-matrix.md`) seven files are still made by a tool that runs only on a Mac: five compiled asset catalogs (`Assets.car`: the app's own, and one in each of four package resource bundles) and the two loose icon PNGs that `actool --compress-pngs` writes next to the app's catalog (rows 7 to 9). Every build so far copied them from an Xcode-built copy of the same app.

That works for an app that has such a copy and whose catalogs did not change. A new app has no copy, and an app whose icon or whose package version changes has an out-of-date one. Nothing else in the IPA needs the Mac any more: build 17 has no storyboard, so `ibtool` is not needed either (row 10).

winCode's own `Assets.car` writer is the clean-room track (PNG only for now; no open format description covers vector and packed renditions). It is separate and later. The maintainer decided on 2026-11-19 that a cloud job on a macOS runner is the first producer of these files. This record is its design.

## Decision

- One generic workflow, started by hand (`workflow_dispatch`), in the user's own private repository. It runs `actool` and Apple's `assetutil`, and nothing else of Xcode: no Flutter, no build of the app, no `ibtool`.
- The inputs are named in a file and hashed. The hash is the cache key. A hash that has been made before costs no macOS minute.
- The flags are Xcode's own, taken from a capture of Xcode's invocation. They are not written from memory.
- The output is the files and a `manifest.json`. The assembler takes the manifest as the producer of rows 7 to 9 and checks every file against it.
- The output is checked in three rungs: `assetutil` against the reference, the Simulator, TestFlight with a device (section 8).
- Nothing in the job needs a secret, a signature or an Apple account.

## 1. What it makes

| Kind | Count in the measured app | Output |
| --- | ---: | --- |
| App catalog (app icon, launch colour and image) | 1 | `Assets.car`; the loose CgBI icon PNGs (the sample's were `AppIcon60x60@2x.png` and `AppIcon76x76@2x~ipad.png`); `partial-Info.plist`, which holds the `CFBundleIcons` keys |
| Package catalog (vector, PDF and PNG image sets) | 4 | one `Assets.car` each, for the package's resource bundle |

The files are Apple tools' output, so the job never publishes them: it runs only in a private repository (section 2).

## 2. Where it runs

- **The file:** `wincode-assets.yml`, beside the build workflow of the same repository, with its own contract line (`# wincode-assets-contract: 1`). Its actions are pinned to full commit SHAs, as the build workflow's are, and each SHA is checked against its release tag when the file is written.
- **When:** `workflow_dispatch` only, so no pull request and no push starts it. `permissions: contents: read`.
- **Private only:** the first job stops with a message when `github.event.repository.private` is not true, before any macOS job exists. The existing oracle workflows run in a public repository and upload nothing; this one has nothing to do there. There is no override in the first version.
- **Three jobs:**

| Job | Runner | Does |
| --- | --- | --- |
| `plan` | `ubuntu-24.04` | Reads the input file, fetches the inputs, checks them, computes the hash, looks in the cache. Uploads the checked inputs as a one-day artifact. |
| `compile` | `macos-26`, `timeout-minutes` set | Runs only when the cache missed. Makes the files, checks them, writes the manifest, saves the cache. |
| `deliver` | `ubuntu-24.04` | Restores the cache entry and uploads it as the artifact `wincode-assets-<first 12 hex of the hash>` (one day), with a `.sha256` file, as the build workflow does. |

The inputs go through `plan` so that the Mac does no `git` work and so that the hash is fixed before a macOS minute is spent.

## 3. Inputs: `wincode-assets.json`

Written by hand in the first version. A generic example:

```json
{
  "format": 1,
  "xcode": { "version": "26.6", "build": "17F113" },
  "platform": "iphoneos",
  "minimum_deployment_target": "15.0",
  "target_devices": ["iphone", "ipad"],
  "catalogs": [
    { "name": "app", "kind": "app", "app_icon": "AppIcon",
      "source": { "repo": "ios/Runner/Assets.xcassets" },
      "install": "Assets.car" },
    { "name": "package-one", "kind": "bundle",
      "source": { "git": "https://example.com/owner/package.git",
                  "commit": "<40 hex characters>",
                  "path": "Sources/Target/Media.xcassets" },
      "install": "<bundle folder>.bundle/Assets.car" }
  ]
}
```

- **Sources:** `repo` is a folder of the checked-out ref. `git` is a URL, a full commit and a folder. A branch name or a tag is refused: only a full commit names its inputs. `plan` fetches that commit, checks that it got it, and takes the folder. A source that cannot be fetched stops the run on the Linux runner, before any macOS minute.
- **Settings:** the values Xcode gets from the app's build settings: the minimum deployment target, the device families, the development region, the app icon name and the bundle identifier. Most are in the Xcode-built copy's `Info.plist` (`MinimumOSVersion`, `UIDeviceFamily`, `CFBundleDevelopmentRegion`, `CFBundleIconName`, `CFBundleIdentifier`) and are read from there. A build setting that the `Info.plist` does not hold (an accent colour name, say) is found by step 0's capture, not guessed.
- **`install`:** the path inside `Runner.app` that the file goes to.
- **Not supported in the first version:** catalogs that sit inside a pub package, and a catalog that is the output of another tool.

## 4. The hash and the cache

**The hash** `inputs_sha256` is the SHA-256 of a canonical text, one line each: the contract version; the Xcode version and build; the SHA-256 of the recipe (section 5); the settings in a fixed order; and, for each catalog in file order, its name, kind, app icon, `install` and the git tree ID of its folder.

Git tree IDs are used instead of file hashes on purpose. A checkout on Windows may change line endings, and then a hash of the files would differ from the runner's. A tree ID is the content as git stores it, so the PC and the runner get the same value from the same commit. The function is written once, with golden values in a test, and runs on the PC and in `plan`.

**Two places hold a result:**

- **The PC's store** `%USERPROFILE%\.wincode\resources\<inputs_sha256>\` is the durable copy. It is filled by downloading the artifact and checking every file against the manifest. A hash found there means no run at all.
- **The Actions cache**, key `wincode-assets-<hash>`, is the guard for a run started by hand: `plan` looks the key up without downloading it (`lookup-only`); on a hit `compile` is skipped. GitHub removes an entry that has not been used for 7 days and keeps a limited size per repository (re-check both when this is built), and an entry made on one branch is visible only to that branch and the default branch. So a hit can be missed, which costs a run and nothing else. That is why the PC's store, not the cache, is the record.

**No cache per catalog.** The job takes about as long for one catalog as for five; its time is the start of the Mac. A per-catalog key would save seconds and add a second kind of hit.

## 5. The flags

The recipe, `recipe.json`, holds for each kind (`app`, `bundle`) the full argument list of `actool`, with the input folder, the output folder and the settings as placeholders. It lives with the workflow. Its SHA-256 is in the hash.

**Where the flags come from.** The flags of the sample (`docs/formats/assets-car-app-icon.md`) are a start: `--platform`, `--minimum-deployment-target`, `--target-device` (twice), `--app-icon`, `--output-partial-info-plist`, `--output-format`, `--notices`, `--warnings`. Xcode's own invocation for an app catalog adds, as the same record says: `--compress-pngs`, `--development-region`, `--enable-on-demand-resources`, `--bundle-identifier`, `--export-dependency-info`, `--generate-asset-symbol-index`, `--generate-objc-asset-symbols`, `--generate-swift-asset-symbols`, and a first pass with `--print-asset-tag-combinations`. It does not pass `--errors`.

**What is not known.** The record keeps flag names, not values or order, and its source artifact has expired. The invocation Xcode makes for a package's resource bundle has never been captured. So the recipe cannot be written yet, and it is not written from memory.

**Step 0, before the job exists.** One run of the existing oracle workflow, extended to build a generic app and a generic one-catalog package and to save Xcode's `actool` command lines for both kinds. They are written down in `docs/formats/assets-car-recipe.md` as an observation, as the other format notes are (clean room: outputs and command lines only), and the recipe is written from that note.

**Rules for the recipe:**

- Every flag Xcode passes is passed, including the ones that only write side files (the dependency info, the generated symbol files, the tag combinations). Their output goes to a scratch folder and is not delivered.
- `--compress-pngs` is in the recipe. It is what makes the loose icon PNGs Apple's CgBI variant. The PNGs are copied byte for byte afterwards and never re-encoded.
- Whether the first pass (`--print-asset-tag-combinations`) must run for the second pass to give the same bytes is answered by step 0's capture and by the check of section 8, not assumed.
- The recipe is valid for one Xcode build. The job stops at its first step, after one billed minute, when `xcodebuild -version` or `actool --version` differs from the input file.
- If a difference from Xcode's own output is found, the recipe is wrong, and the first rung finds it.

## 6. The `compile` job

1. Select the pinned Xcode, assert its version and build, save `versions.txt` (as the oracle workflow does).
2. Download the checked inputs.
3. For each catalog, run `actool` with the recipe. The command line, the output and the exit status are saved. A non-zero exit fails the job; warnings are listed in the manifest.
4. On the first run only (`determinism: true`), compile each catalog twice and compare the bytes and the `assetutil` dumps without `Timestamp`. This is reported, not enforced. It answers whether the same inputs give the same bytes, which decides whether "equal bytes" can ever be used as a test.
5. Run `assetutil --info` on every `Assets.car`. When a `reference/` folder exists in the repository (the Xcode-built copy's five catalogs and two PNGs, taken from its IPA), run it on those too and compare (section 8, rung 1).
6. Write the manifest, save the cache, upload.

## 7. The output and the manifest

```
resources/<inputs_sha256>/
  manifest.json
  app/Assets.car
  app/AppIcon60x60@2x.png            (CgBI)
  app/AppIcon76x76@2x~ipad.png       (CgBI)
  app/partial-Info.plist
  package-one/Assets.car
  ...
  checks/   versions.txt, actool-<name>.txt, assetutil-<name>.json, rung1.txt
```

`manifest.json` holds: the format; `inputs_sha256`; the Xcode, `actool`, `assetutil` and SDK versions; for each catalog its name, kind, source (the commit and folder, or the repo path) and tree ID; for each delivered file its path, size, SHA-256, `install` path and producer-matrix row; the `actool` command line with placeholders; the warnings; and the result of the checks. It holds no bundle ID and no path of the user's.

**The assembler** (the code that fills an IPA's folder):

- reads `manifest.json`; refuses it when `inputs_sha256` differs from its own computation over the current inputs, or when a file's SHA-256 differs from the manifest. Output made for other inputs is never used;
- puts each file at `Runner.app/<install>`, without changing a byte;
- compares `partial-Info.plist`'s icon keys with the `Info.plist` that it merges, and reports a difference. Taking those keys from it is a later step;
- with no manifest, keeps today's behaviour: copy from the Xcode-built copy.

Rows 7 to 9 of the matrix then read "made by the cloud job", with "Proven" only after rung 3.

## 8. How the output is checked

| Rung | What | Where | Passes when |
| --- | --- | --- | --- |
| 1. `assetutil` | `assetutil --info` of each catalog against the reference's, and the two PNGs against the reference's, byte for byte | In the job, so both dumps come from the same `assetutil` | Every entry equal (all fields except `Timestamp`); the header's version fields are listed, not hidden; the PNGs equal. Whether the `Assets.car` bytes are equal is reported, and is not the criterion |
| 2. Simulator | The catalogs loaded in the Simulator | See below | See below |
| 3. TestFlight and a device | The next build, assembled with the job's files | The maintainer's iPhone | `tools/ipa-diff` against build 17 shows only the catalog and PNG differences, `tools/ipa-declarations` still 4 of 4, sign, preflight and the upload dry run pass, STOP for UPLOAD, then valid in App Store Connect, and on the device the app icon, the launch colour, and the screens that show a package's images (the payment sheet opens) look as before |

If the reference was made with another Xcode build than the pinned one, rung 1's header differs and the entries may too. The Xcode build of the reference is in its `Info.plist` (`DTXcodeBuild`). When the runner image has that Xcode, pin it. When it does not, a difference in the entries is a finding to report, not to hide.

**Rung 2 is not recommended for this job.** The files are made by Apple's own tool, and the Simulator reads them with the same framework as `assetutil`. All it can find is a wrong flag, such as a deployment target, and rung 1's header fields and entries show that too. The rung is worth its cost for winCode's own writer (the separate track), where nothing guarantees that the file loads. If the maintainer wants it here anyway, it is one more step in `compile`: boot a Simulator, load every rendition by name in a generic test app, compare the decoded pixels with the reference. Not measured: a few minutes more, and a test app to write.

## 9. What a run costs

Minutes only, as in ADR-0015: winCode shows no prices. The macOS multiplier that some plans apply to the included minutes is not in these numbers. The measured facts: the oracle workflows' runs took 1.5 to 2.6 minutes of wall time, and the first real `wincode build` job (a made-up app) took about 2 minutes and was billed 3 macOS minutes, because each job is rounded up. A real app's unsigned IPA took about 7.

| Run | macOS minutes billed | Linux minutes billed | Status |
| --- | ---: | ---: | --- |
| Step 0, the capture (the oracle workflow, extended) | about 3 to 4 | 0 | Estimate: the oracle's runs plus a small package fixture |
| `compile`, the first time (with the determinism check and the reference compare) | about 2 to 3 | 2 | Estimate: no Flutter, no pods, no build of the app |
| `compile`, later, hash changed | about 2 | 2 | Estimate |
| Hash already in the PC's store | 0 | 0 | No run |
| Hash in the Actions cache, run started by hand | 0 | 2 | `plan` and `deliver` only |
| Wrong Xcode build (the job stops at its first step) | 1 | 1 | Measured pattern: "after a billed minute" (ADR-0015) |

The estimates are replaced by the first runs' measured times. After that, a run happens only when an input changes: the app icon or launch art, a package version whose catalogs changed, the Xcode build. A release with code changes only costs none.

## 10. What the maintainer types

- **`RUN`**, exactly, for each macOS run. This design has two before it is useful: step 0 (the capture), then the first `compile`. After those, one `RUN` each time the hash changes. A run that stops at its first step because the Xcode build differs also needs it.
- The maintainer starts the run, from their own terminal or the Actions page, with their own token. A coding agent never holds the token and never dispatches.
- **`UPLOAD`**, exactly, for the build made with the job's files, as for every upload.

Decisions for the maintainer, with a recommendation each:

1. **Which repository runs the first `compile`.** Recommended: the private test repository, with the four package catalogs (public sources, pinned by commit) and a generic placeholder app catalog. The real app's own catalog is the app owner's art; it goes into the owner's private repository only when the maintainer decides so.
2. **Two runs or one.** Recommended: two, as above. One run is possible if `compile` also captures Xcode's invocation, but then a recipe is written and used in the same run and a wrong guess costs a whole run.
3. **Rung 2.** Recommended: skip it for this job (section 8).

## 11. Risks and what is not known

- The package-bundle invocation has never been captured. If Xcode passes other flags for a package's bundle than for the app's catalog, the recipe has two kinds, as designed, and step 0 decides the second.
- The reference may have been made with another Xcode build. Rung 1 then reports differences that are not the recipe's.
- Whether the same inputs give the same bytes is unknown until the first run's determinism check. If they do not, a stored result is still a valid result of one run, but "equal bytes" cannot be a test.
- The runner image changes Xcode from time to time. The job stops by design, and the recipe is captured again for the new build.
- `assetutil`'s output format is Apple's and may change between versions; rung 1 compares two dumps made by the same version.
- A catalog in a pub package is not covered, and not every app will have one in a git package.
- Whether `partial-Info.plist` should feed the merged `Info.plist` is left open.

## Consequences

- An app whose catalogs change no longer needs a full build on a Mac, and an app with no Xcode-built copy can get its catalogs at all. The Mac does one thing, in a job of a few minutes, and only when an input changes.
- Rows 7 to 9 of the matrix change from "copied" to "made by the cloud job" once rung 3 passes. The storyboard needs nothing (row 10).
- A new file contract (`wincode-assets.json`, `recipe.json`, `manifest.json`) and a private repository per user have to be kept. Each new Xcode build needs a new capture.
- Not decided here: the `wincode` commands that compute the hash, check the store, dispatch and download. They are a later part, as `build` was.
- Revisit when winCode's own `Assets.car` writer covers vector and packed renditions: the job then stays only as the oracle that the writer is checked against.

## Alternatives considered

- **Copy from an Xcode-built copy (today).** Needs a copy per app and per change of the catalogs, and a Mac build to make it.
- **A full `flutter build ipa` on the runner for every build (the cloud Mac lane).** About 7 minutes of macOS for a real app on every build, to get five files that rarely change.
- **`xcodebuild` on a generated project, so that Xcode chooses the flags.** The flags are Xcode's by construction, but the generated project's settings must match the app's, and a package's resource bundle is not made the way a project's target is. Kept as the fallback if direct `actool` cannot reproduce the reference's entries.
- **Reading `actool` itself to learn its flags.** Not allowed: Apple's tools are never looked inside (CLAUDE.md, PLAN). Command lines and outputs only.
- **winCode's own `Assets.car` writer now.** It is the separate clean-room track and does not cover vector and packed renditions yet.
- **Only the Actions cache, no store on the PC.** The cache forgets after 7 days without use, so the job would run again for inputs that did not change.
- **A per-catalog hash.** Saves seconds, not minutes (section 4).

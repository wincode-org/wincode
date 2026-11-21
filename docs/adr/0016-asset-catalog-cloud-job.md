# 0016. A cloud job compiles asset catalogs with `actool` (D1)

- Status: Proposed
- Date: 2026-11-21

Design. One run has been made for it: step 0, the capture of Xcode's own `actool` invocations (2026-11-21, 3 min 4 s; section 5 and `docs/formats/assets-car-recipe.md`). Nothing of the job itself is built. Every macOS run of this design needs the maintainer's word RUN.

## Context

In the measured app (`docs/producer-matrix.md`) seven files are still made by a tool that runs only on a Mac: five compiled asset catalogs (`Assets.car`: the app's own, and one in each of four package resource bundles) and the two loose icon PNGs next to the app's catalog (rows 7 to 9). The matrix says that `actool --compress-pngs` writes those PNGs as CgBI; the capture did not show that (section 5), so they are not part of the job until a run does. Every build so far copied all seven files from an Xcode-built copy of the same app.

That works for an app that has such a copy and whose catalogs did not change. A new app has no copy, and an app whose icon or whose package version changes has an out-of-date one. Nothing else in the IPA needs the Mac any more: build 17 has no storyboard, so `ibtool` is not needed either (row 10).

winCode's own `Assets.car` writer is the clean-room track (PNG only for now; no open format description covers vector and packed renditions). It is separate and later. The maintainer decided on 2026-11-19 that a cloud job on a macOS runner is the first producer of these files. This record is its design.

## Decision

- One generic workflow, started by hand (`workflow_dispatch`), in the user's own private repository. It runs `actool` and Apple's `assetutil`, and nothing else of Xcode: no Flutter, no build of the app, no `ibtool`.
- The inputs are named in a file and hashed. The hash is the cache key. A hash that has been made before costs no macOS minute.
- The flags are Xcode's own, from a capture of Xcode's invocations (done: section 5). They are not written from memory.
- The recipe is proven before the job is built: a first run replays it next to Xcode's own build of the same catalogs and compares the bytes (section 12).
- The output is the files and a `manifest.json`. The assembler takes the manifest as the producer of rows 7 and 8 (the catalogs) and checks every file against it. Row 9 (the loose PNGs) only if the proof run shows how they are made.
- The output is checked in three rungs: `assetutil` against the reference, the Simulator, TestFlight with a device (section 8).
- Nothing in the job needs a secret, a signature or an Apple account.

## 1. What it makes

| Kind | Count in the measured app | Output |
| --- | ---: | --- |
| App catalog (app icon, launch colour and image) | 1 | `Assets.car`; `partial-Info.plist`, which holds the `CFBundleIcons` keys. The loose icon PNGs (`AppIcon60x60@2x.png` and `AppIcon76x76@2x~ipad.png` in the capture) only if section 12 shows how the CgBI ones are made |
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
  "development_region": "en",
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
- **Settings:** the values Xcode gets from the app's build settings: the minimum deployment target, the device families, the development region and the app icon name. Most are in the Xcode-built copy's `Info.plist` (`MinimumOSVersion`, `UIDeviceFamily`, `CFBundleDevelopmentRegion`, `CFBundleIconName`) and are read from there. The bundle identifier is not a setting of the job: the invocation that makes the files does not pass it (section 5).
- **A catalog may override `minimum_deployment_target`.** In the capture the value was 15.0 for the app and for both probes; whether a package that declares another value gets its own or the app's is not shown. The reference's header (`PlatformVersion`) of that package's catalog tells, and rung 1 checks it.
- **A build setting that the `Info.plist` does not hold** (an accent colour name, say) is not in the capture: its apps are Flutter's template. It is read from the reference's `assetutil` entries and checked by rung 1, not guessed.
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

The recipe, `recipe.json`, holds for each kind (`app`, `bundle`) the argument list of the `actool` invocation that makes the files, with the input folder, the output folder and the settings as placeholders. It lives with the workflow. Its SHA-256 is in the hash.

**Where the flags come from: step 0, done.** On 2026-11-21 the oracle workflow, extended by pull request 43, saved the `actool` command lines that Xcode itself passed while building Flutter's template app and two small probes: a Flutter plugin's Swift package built into an app, and a plain Swift package. The observation is `docs/formats/assets-car-recipe.md` (run 44903169894; macOS 26.7.2, Xcode 26.6 build 17F113, `actool` 26.6). The recipe is written from that note and from nothing else.

**What the capture showed, against this ADR's first guess** (which merged every `actool` flag the earlier record named into one invocation):

| The guess | What Xcode does |
| --- | --- |
| One invocation with `--compress-pngs`, `--development-region`, `--enable-on-demand-resources`, `--bundle-identifier`, `--export-dependency-info`, the three `--generate-*` flags, and a first pass with `--print-asset-tag-combinations` | Four tasks. `--print-asset-tag-combinations` is its own pass, once per build, for the app's catalog only. `GenerateAssetSymbols` carries `--bundle-identifier` and the `--generate-*` flags and writes only symbol files. `CompileAssetCatalogVariant thinned` makes the files and carries neither. `builtin-linkAssetCatalog` copies its results into the `.app` and is not `actool` |
| `--enable-on-demand-resources` is a flag | It takes a value: `YES` for the app's catalog, `NO` for a package's |
| Two kinds of recipe if the bundle's differs | Two kinds, and they differ in two places: `--app-icon AppIcon` (app only) and that value |
| Xcode passes no `--errors` | Right, in every invocation of the capture |
| `--compress-pngs` makes the loose icon PNGs CgBI | Not in the `build` action: the flag was passed and the two PNGs are plain PNG files. A store IPA made by Xcode has CgBI ones. Where the conversion happens is open (section 12) |

**The recipe of each kind is the `CompileAssetCatalogVariant thinned` line,** flag for flag, in Xcode's order, as the note gives it. The app's line, with `<…>` for the placeholders:

```
actool <catalog> --compile <out> --output-format human-readable-text --notices --warnings
  --export-dependency-info <dependencies> --output-partial-info-plist <partial-info-plist>
  --app-icon <app icon> --compress-pngs --enable-on-demand-resources YES --development-region <region>
  --target-device iphone --target-device ipad --minimum-deployment-target <minimum> --platform iphoneos
```

The package's line has no `--app-icon` and has `NO`.

**Rules for the recipe:**

- The recipe is the file-making invocation only. The symbol pass is not run, because its results are not delivered, and neither is the tag-combination pass. Section 12 tests whether the bytes depend on either; if they do, the recipe changes.
- `--export-dependency-info` and `--output-partial-info-plist` are passed, with their files in a scratch folder, because they are part of Xcode's line. The partial plist is delivered for the app (section 7).
- `--compress-pngs` is passed, as Xcode passes it. What it does to the loose PNGs is not assumed: if the proof run shows that they come out plain, the job does not deliver them.
- The recipe is valid for one Xcode build. The job stops at its first step, after one billed minute, when `xcodebuild -version` or `actool --version` differs from the input file.
- If a difference from Xcode's own output is found, the recipe is wrong, and the first rung finds it.

## 6. The `compile` job

1. Select the pinned Xcode, assert its version and build, save `versions.txt` (as the oracle workflow does).
2. Download the checked inputs.
3. For each catalog, run `actool` with the recipe. The command line, the output and the exit status are saved. A non-zero exit fails the job; warnings are listed in the manifest.
4. On the first run only (`determinism: true`), compile each catalog twice and compare the bytes and the `assetutil` dumps without `Timestamp`. This is reported, not enforced. It answers whether the same inputs give the same bytes, which decides whether "equal bytes" can ever be used as a test.
5. Run `assetutil --info` on every `Assets.car`. When a `reference/` folder exists in the repository (the Xcode-built copy's five catalogs, taken from its IPA), run it on those too and compare (section 8, rung 1). The reference holds the owner's art, so it belongs only in the owner's private repository, never in a shared or test one.
6. Write the manifest, save the cache, upload.

## 7. The output and the manifest

```
resources/<inputs_sha256>/
  manifest.json
  app/Assets.car
  app/partial-Info.plist
  package-one/Assets.car
  ...
  checks/   versions.txt, actool-<name>.txt, assetutil-<name>.json, rung1.txt
```

The app's two loose icon PNGs are not in the output yet. They stay copied from the Xcode-built copy until section 12 shows how the CgBI ones are made.

`manifest.json` holds: the format; `inputs_sha256`; the Xcode, `actool`, `assetutil` and SDK versions; for each catalog its name, kind, source (the commit and folder, or the repo path) and tree ID; for each delivered file its path, size, SHA-256, `install` path and producer-matrix row; the `actool` command line with placeholders; the warnings; and the result of the checks. It holds no bundle ID and no path of the user's.

**The assembler** (the code that fills an IPA's folder):

- reads `manifest.json`; refuses it when `inputs_sha256` differs from its own computation over the current inputs, or when a file's SHA-256 differs from the manifest. Output made for other inputs is never used;
- puts each file at `Runner.app/<install>`, without changing a byte;
- compares `partial-Info.plist`'s icon keys with the `Info.plist` that it merges, and reports a difference. Taking those keys from it is a later step;
- with no manifest, keeps today's behaviour: copy from the Xcode-built copy.

Rows 7 and 8 of the matrix then read "made by the cloud job", with "Proven" only after rung 3. Row 9 stays "copied" until section 12 settles the loose PNGs.

## 8. How the output is checked

| Rung | What | Where | Passes when |
| --- | --- | --- | --- |
| 1. `assetutil` | `assetutil --info` of each catalog against the reference's | In the job, so both dumps come from the same `assetutil` | Every entry equal (all fields except `Timestamp`, which the recipe note shows is not in the file's bytes); the header's version fields are listed, not hidden. Whether the `Assets.car` bytes are equal is reported, and is not the criterion |
| 2. Simulator | The catalogs loaded in the Simulator | See below | See below |
| 3. TestFlight and a device | The next build, assembled with the job's files | The maintainer's iPhone | `tools/ipa-diff` against build 17 shows only the catalog differences, `tools/ipa-declarations` still 4 of 4, sign, preflight and the upload dry run pass, STOP for UPLOAD, then valid in App Store Connect, and on the device the app icon, the launch colour, and the screens that show a package's images (the payment sheet opens) look as before |

If the reference was made with another Xcode build than the pinned one, rung 1's header differs and the entries may too. The Xcode build of the reference is in its `Info.plist` (`DTXcodeBuild`). When the runner image has that Xcode, pin it. When it does not, a difference in the entries is a finding to report, not to hide.

**Rung 2 is not recommended for this job.** The files are made by Apple's own tool, and the Simulator reads them with the same framework as `assetutil`. All it can find is a wrong flag, such as a deployment target, and rung 1's header fields and entries show that too. The rung is worth its cost for winCode's own writer (the separate track), where nothing guarantees that the file loads. If the maintainer wants it here anyway, it is one more step in `compile`: boot a Simulator, load every rendition by name in a generic test app, compare the decoded pixels with the reference. Not measured: a few minutes more, and a test app to write.

## 9. What a run costs

Minutes only, as in ADR-0015: winCode shows no prices. The macOS multiplier that some plans apply to the included minutes is not in these numbers. The measured facts: the oracle workflows' runs took 1.5 to 2.6 minutes of wall time, and the first real `wincode build` job (a made-up app) took about 2 minutes and was billed 3 macOS minutes, because each job is rounded up. A real app's unsigned IPA took about 7. Step 0, the capture run, took 3 min 4 s (the job 3 min 0 s) and was billed 4 macOS minutes: the organisation's usage report for the month went from 3 to 7.

| Run | macOS minutes billed | Linux minutes billed | Status |
| --- | ---: | ---: | --- |
| Step 0, the capture (the oracle workflow, extended) | 4 (the run took 3 min 4 s) | 0 | Measured, run 44903169894. The estimate was 3 to 4 |
| The proof run (section 12) | about 5 to 6 | 0 | Estimate: step 0's run, plus an archive of the template app (about 1 to 1.5 minutes) and the replays |
| `compile`, the first time on real inputs (with the determinism check and the reference compare) | about 2 to 3 | 2 | Estimate: no Flutter, no pods, no build of the app |
| `compile`, later, hash changed | about 2 | 2 | Estimate |
| Hash already in the PC's store | 0 | 0 | No run |
| Hash in the Actions cache, run started by hand | 0 | 2 | `plan` and `deliver` only |
| Wrong Xcode build (the job stops at its first step) | 1 | 1 | Measured pattern: "after a billed minute" (ADR-0015) |

The estimates are replaced by the first runs' measured times. After that, a run happens only when an input changes: the app icon or launch art, a package version whose catalogs changed, the Xcode build. A release with code changes only costs none.

## 10. What the maintainer types

- **`RUN`**, exactly, for each macOS run. Step 0 (the capture) is done. Two more come before the job is useful: the proof run (section 12), then the first `compile` on real inputs. After those, one `RUN` each time the hash changes. A run that stops at its first step because the Xcode build differs also needs it.
- The maintainer starts the run, from their own terminal or the Actions page, with their own token. A coding agent never holds the token and never dispatches.
- **`UPLOAD`**, exactly, for the build made with the job's files, as for every upload.

Decisions for the maintainer, with a recommendation each:

1. **Which repository runs what.** Recommended: the proof run in the private test repository, with generated, generic catalogs only (section 12); the first `compile` on real inputs in the owner's private repository, because the reference and the real art are the owner's and never go into a shared or test repository. The four packages' catalogs (public sources, pinned by commit) can go to either.
2. **The archive in the proof run.** Recommended: include it. The capture covered the `build` action only, and the loose PNGs are CgBI in a store IPA and plain in the `build` action's output. An archive of the template app adds about 1 to 1.5 macOS minutes and answers, in the same run, whether the `archive` action differs and whether the PNGs are CgBI there. The alternative is a separate capture run first, which costs another run's minimum.
3. **Rung 2.** Recommended: skip it for this job (section 8).

## 11. Risks and what is not known

- The capture is of Xcode's `build` action. Whether the `archive` and export actions run the same invocation and give the same files is open, and so is where the loose icon PNGs become CgBI: the matrix's sentence that `--compress-pngs` writes them is not supported by the capture (section 12 tests it).
- The capture's catalogs are Flutter's template and a one-image probe. Vector, PDF, colour and accent-colour catalogs, and a package that declares another deployment target than the app, are not covered. The proof run adds some; rung 1 on real inputs covers the rest.
- The reference may have been made with another Xcode build. Rung 1 then reports differences that are not the recipe's.
- In the capture, the same app catalog compiled by Xcode in three apps, and the same package catalog in two builds, gave byte-identical files, on one runner image. Whether `actool` started alone, and other runs and images, give the same bytes is for the proof run. If they do not, a stored result is still a valid result of one run, but "equal bytes" cannot be a test.
- The runner image changes Xcode from time to time. The job stops by design, and the recipe is captured again for the new build.
- `assetutil`'s output format is Apple's and may change between versions; rung 1 compares two dumps made by the same version.
- A catalog in a pub package is not covered, and not every app will have one in a git package.
- Whether `partial-Info.plist` should feed the merged `Info.plist` is left open.

## 12. The first run: proving the recipe

The first run is not the job. It is the oracle workflow (`oracle-reference-builds.yml`), extended once more, in the private test repository, with catalogs that the run generates itself. It replays the recipe next to Xcode's own build of the same catalogs and compares the bytes. The job (sections 2 to 7) is built after it, from a recipe that has passed.

**Why not the job first.** The job has no Xcode build to compare with. The capture left three questions that only a comparison answers: does `actool`, started alone with Xcode's line, give Xcode's bytes; does the `archive` action differ from `build`; and where do the loose icon PNGs become CgBI.

**New files** (one pull request, no macOS minute): `tools/asset-recipe/recipe.json`, the recipe of section 5 for the two kinds, and `tools/asset-recipe/compile.py`, which fills the placeholders, runs `actool` and saves the command line, the output and the exit status. The job's step 3 will run the same script, so the proof run tests the code that the job uses.

**Inputs** (none comes from an owner):

- the app kind: the catalog that `flutter create` writes, which is also Xcode's input for it in the same run, so nothing is fetched;
- the bundle kind: the capture's probe catalog (the same generator, so its SHA-256, `e25626d6…`, can be reproduced), and a second one, "rich", that has what real packages have and the probe lacks: an SVG and a PDF image set that preserve vectors, an image set at 1x, 2x and 3x, and a colour set with a dark variant. The rich catalog is a second target of the plain probe package, so a failure in it leaves the first one's result.

**Steps**, in the existing macOS job, after step 0's:

1. **Archive:** `flutter build ipa --no-codesign` of the template app. It runs `xcodebuild archive` and stops before the export (Flutter 3.47.7 skips the IPA with that flag). Save its `actool` lines; hash `Assets.car` and the two PNGs inside `Runner.xcarchive`; test the PNGs for the `CgBI` chunk.
2. **Xcode's own files, saved for comparison:** the `Runner.app` files of the earlier `build` action, and the files in Xcode's `assetcatalog_output/thinned` folder, so that "`LinkAssetCatalog` copies them unchanged" is checked and not assumed.
3. **Replay:** run `compile.py` on each catalog into a scratch folder.
4. **Compare**, by SHA-256:

   | Replay of | Compared with, from the same run |
   | --- | --- |
   | The app catalog | `Assets.car`, both PNGs and `partial-Info.plist` of the `build` action (the thinned folder and `Runner.app`); `Assets.car` and both PNGs of the archive |
   | The probe catalog | `Assets.car` of probe A and of probe B |
   | The rich catalog | `Assets.car` of its bundle, built by `xcodebuild` |

5. **Four ablations** on the app catalog, each compared with Xcode's: the recipe run twice (determinism); with the tag-combination pass run first; without `--compress-pngs`; with the symbol pass's flags added. And the bundle recipe run twice.
6. **`assetutil --info`** of every replayed `Assets.car`; where the bytes differ, the replay's and Xcode's dumps without `Timestamp`, diffed.
7. **`replay-report.txt`:** one line per comparison (equal or not, sizes, SHA-256), the ablations, and the `CgBI` test. Uploaded with the rest of `xcode-dumps`.

**It reports, it does not fail on a difference.** A run that finds one is a result, not a loss. It fails only when a step cannot run at all, as the capture's last step does.

**What it settles.** Whether the recipe reproduces Xcode's files, and if not, how it differs. Whether replay is deterministic. Whether the tag-combination pass or `--compress-pngs` change any byte. Whether the archive's files equal the build's. Whether the loose PNGs are CgBI in the archive. If they are not, the conversion happens in the export or later, and the job never makes them: they stay copied from the Xcode-built copy. A converter from a plain PNG to the CgBI variant would be a separate clean-room task, and not necessary for the store to accept the app.

**What it does not settle.** Real packages' catalogs, a catalog with an accent colour, an app or a package that declares another deployment target, another Xcode build, the export step itself, and the job's own plumbing (plan, cache, deliver, manifest, assembler).

**Pass.** Every `Assets.car` comparison equal in bytes; or, where the bytes differ, every `assetutil` entry equal (all fields except `Timestamp`) and the differences listed, which makes rung 1's criterion the standard for the job. Any other result is reported and the recipe is corrected before the job is built.

**Cost:** about 5 to 6 macOS minutes billed (section 9). The job's `timeout-minutes` stays 30, and each new step has its own limit.

**How it is started:** prepared as step 0 was: a pull request for the workflow and the two files, and a branch of the private test repository with a copy of them under the file name that repository registers. The maintainer starts it, after `RUN`, with their own token. After it: the note and this record are corrected from the report, then the job and the assembler are built in their own pull requests (no minutes), and the first `compile` on real inputs follows, with the owner's reference and its own `RUN`.

## Consequences

- An app whose catalogs change no longer needs a full build on a Mac, and an app with no Xcode-built copy can get its catalogs at all. The Mac does one thing, in a job of a few minutes, and only when an input changes.
- Rows 7 and 8 of the matrix change from "copied" to "made by the cloud job" once rung 3 passes. Row 9 (the loose PNGs) stays "copied" until section 12 settles it, and its wording ("`--compress-pngs`, which writes Apple's CgBI variant") needs a correction that this record does not make. The storyboard needs nothing (row 10).
- A new file contract (`wincode-assets.json`, `recipe.json`, `manifest.json`) and a private repository per user have to be kept. Each new Xcode build needs a new capture.
- Not decided here: the `wincode` commands that compute the hash, check the store, dispatch and download. They are a later part, as `build` was.
- Revisit when winCode's own `Assets.car` writer covers vector and packed renditions: the job then stays only as the oracle that the writer is checked against.

## Alternatives considered

- **Copy from an Xcode-built copy (today).** Needs a copy per app and per change of the catalogs, and a Mac build to make it.
- **A full `flutter build ipa` on the runner for every build (the cloud Mac lane).** About 7 minutes of macOS for a real app on every build, to get five files that rarely change.
- **`xcodebuild` on a generated project, so that Xcode chooses the flags.** The flags are Xcode's by construction, but the generated project's settings must match the app's, and a package's resource bundle is not made the way a project's target is. Kept as the fallback if direct `actool` cannot reproduce the reference's entries.
- **Reading `actool` itself to learn its flags.** Not allowed: Apple's tools are never looked inside (CONTRIBUTING.md, PLAN). Command lines and outputs only.
- **winCode's own `Assets.car` writer now.** It is the separate clean-room track and does not cover vector and packed renditions yet.
- **Only the Actions cache, no store on the PC.** The cache forgets after 7 days without use, so the job would run again for inputs that did not change.
- **A per-catalog hash.** Saves seconds, not minutes (section 4).

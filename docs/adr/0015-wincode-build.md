# 0015. wincode build: the unsigned IPA from a GitHub macOS runner

- Status: Accepted
- Date: 2026-11-15
- Amended: 2026-11-15, after review: the Flutter release and the oldest Xcode come from the project and are checked before the dispatch (section 2); `auto` is the default build number in a file of apps (section 3); the maintainer's answers to the open questions are decisions (section 14)
- Amends: ADR-0013 (sections 1, 3, 6, 7, 8 and 11, phase 5 in section 10, and the alternative "The REST API instead of `gh`") and ADR-0014 (sections 1, 6 and 8). Design only when it was written: nothing here was implemented, and no macOS workflow was run for it. The lines below record what was built and run since.
- Amended: 2026-11-15, while building part 5a: the Flutter release's tag must exist in `flutter/flutter`, which one read checks before the dispatch (section 2); the ids and details that the code settled where this ADR was silent ("As built: part 5a", section 13)
- Amended: 2026-11-15, while building part 5b: a run that builds another commit than the one the checks read stops the build (`ref-moved`, section 4) instead of giving a warning; the ids and details that the code settled where this ADR was silent ("As built: part 5b", section 13)
- Verified: 2026-11-15, a rehearsal on a Linux runner confirmed the GitHub behaviour that the design relies on: the dispatch's answer, `display_title`, what `digest` covers, the artifact's zip with `wincode_core`'s reader, and which copy of the workflow runs (section 13)
- Verified: 2026-11-15, `wincode build` ran end to end on a Linux runner of the same test repository, with the maintainer's yes: the checks, the dispatch, the wait, the download through GitHub's redirect and every check of the IPA (section 13, "As built: part 5b"). No macOS runner was used
- Amended: 2026-11-16, while building part 5c: contract 2 of the reference workflow, the update path of `init --workflow`, the warning for a workflow that differs from the template (`workflow-differs`), and the INFO line of `doctor --build`; a plain POSIX `awk` compares the Xcode versions, where the first draft used `sort` (section 8, "As built: part 5c")
- Verified: 2026-11-16, `doctor --build` read the contract 2 template and a hand-written workflow of the test repository with GET requests only; nothing was dispatched and no runner was used (section 13, "As built: part 5c")
- Verified: after part 5c, `wincode build` ran for real on a GitHub-hosted macOS runner, for a made-up test app, and `wincode sign` and `wincode upload` then took its IPA to a build that App Store Connect processed as valid (section 13, "The first macOS run")

## Context

- **`build` is the one step of the hybrid lane that winCode does not run yet** (ADR-0013, phase 5). `sign` (on Windows and Linux), `preflight` and `upload` are built. The unsigned IPA still comes from a run that someone starts and downloads by hand, and `wincode build` exits 64 (`not-implemented`).
- **ADR-0013 planned it on `gh`:**
  - `gh workflow run` with a random `request_id`;
  - the run found by the URL that `gh` prints "if available", or by its title `wincode <request_id>`;
  - `gh run watch`, then `gh run download --name unsigned-ipa`;
  - the IPA's checks (section 3).

  ADR-0014 added the inputs `flavor` and `build_number` and one run per app, and refused `--all`.
- **Since then:**
  - **Linux servers are a supported target** (ADR-0013, section 11). A server usually has no `gh`, and nobody at its keyboard.
  - **Another tool will drive `build`.** A brand builder will build the apps of one project, calling `wincode` once per app and step. It has to follow a build of several minutes while it runs, not only read one object at the end.
  - **GitHub's REST API now returns the run it starts.** With API version 2026-03-10, "Create a workflow dispatch event" answers 200 with `workflow_run_id`, `run_url` and `html_url`. The version before answered 204 with no body unless asked (`return_run_details`, which 2026-03-10 removed), which is why ADR-0013 looked the run up by its title. GitHub supports the previous version for at least 24 more months.
- **What real builds need that the reference workflow cannot give:**
  - an App Store version that runs ahead of the Android one, so not `pubspec.yaml`'s;
  - a build number per app, since App Store Connect keeps one sequence per app record and `pubspec.yaml` has one number for all of them;
  - an entry point per flavor, such as `lib/main_<flavor>.dart`;
  - nothing passed through `--dart-define`: some projects refuse it and keep each flavor's values in the flavor's own files;
  - the Flutter release that the project is made with, and an Xcode that App Store Connect accepts. Today both are values inside the workflow file, so one workflow cannot vary them per app, and nothing compares them with the project;
  - a check, before any minute is spent, that the flavor's scheme and configuration exist.

  The last need is not theoretical. flutter_tools 3.47 builds the configuration `Release-<Scheme>` for a flavor. When the project has no such configuration, it builds plain `Release` and reports no error (`XcodeProjectInfo.buildConfigurationFor`). The run then succeeds with another configuration's bundle ID, and only the IPA's check finds it, after the minutes are spent.
- **Cost.** On GitHub's billing page, a standard macOS runner costs $0.062 a minute and a standard Linux one $0.006.
  - Standard runners are free in public repositories.
  - A private repository spends its account's included usage, then money. Without a payment method, its runs stop when the included amount is spent.
  - The spikes' oracle runs took 1.5 to 2.6 minutes; a real app's unsigned IPA took about 7.
- **Artifacts** can be downloaded by anyone with read access to the repository until they expire: after 90 days by default, after 1 day in the reference workflow. For a public repository, that is anyone with a GitHub account.

## Decision

### 1. The command

```
wincode build [--app <name>] [--ref <branch or tag>] [--build-name <x.y.z>] [--build-number <n> | --build-number auto]
              [--timeout <minutes>] [--yes] [--allow-public] [--events] [--run <id>]
```

It also takes the global options of ADR-0013: `--config`, `--json`, `--redact`, `--verbose` and `--dry-run`.

| Option | Meaning |
| --- | --- |
| `--app <name>` | The app (ADR-0014, section 3). `--all` is refused (`all-not-allowed`, 64): each run is paid for, and one run builds one app |
| `--ref <branch or tag>` | Build this branch or tag instead of the `@<ref>` of `workflow:`. A 40-hex commit SHA is refused (64): GitHub dispatches a workflow on a branch or a tag, not on a commit |
| `--build-name <x.y.z>` | The version, for this build only (section 2) |
| `--build-number <n>` or `--build-number auto` | The build number (section 3). Without it: `auto` in a file of apps, and `pubspec.yaml`'s number at the ref in a flat file |
| `--timeout <minutes>` | How long to wait for the run, counted from the dispatch: 60 minutes by default, or a number of seconds ending in `s`, as `upload` takes it. It ends the wait, never the run (section 4) |
| `--yes` | Start the run without the question of section 7. Needed with `--json` or `--events`, in CI, and without a terminal |
| `--allow-public` | Build in a public repository (section 6) |
| `--events` | Write progress as JSON lines on stdout (section 9). `sign` and `upload` take it too |
| `--run <id>` | Start nothing: wait for run `<id>`, which an earlier `build` started, then download and check its IPA (section 4). `--ref`, `--build-name` and `--build-number` are refused with it (64), since the run already has them |

**Chaining: there is no `build --then sign,upload` and no `ship` command.**

| Option | For | Against |
| --- | --- | --- |
| A. `build --then sign,upload` | One command line | `upload` asks for the app's name separately because Apple never gives back a used build number. With `--then`, either `build`'s `--yes` would have to stand for that answer, or `upload` would ask in the middle of an unattended run. One exit code and one object for three steps hide which step failed, and the options of three commands share one line |
| B. `wincode ship` now | It is ADR-0008's name for the lane | The same problems, plus a design of its own: a plan of the three steps before anything starts, one confirmation up front, a record so that a second run resumes after the failed step instead of building again, events across the steps, and a mapping of exit codes. ADR-0013 (section 9) waits until each step works, and `build` does not exist yet |
| **C. Neither: the caller chains the steps** (chosen) | Each step keeps its exit code, its object and its confirmation. A calling tool already runs one step at a time (ADR-0014, section 7) | Three commands to type, or one shell line |

**C is chosen,** and there is no `ship` for now (section 14). The steps hand over through the app's output folder: `build` writes `unsigned.ipa`, which `sign` reads by default, and `sign` writes `signed.ipa`, which `upload` reads.

```sh
wincode build --app alpha --yes && wincode sign --app alpha && wincode upload --app alpha
```

### 2. What an app builds: inputs in `wincode.yaml`, checked at the ref

**Four new keys** are allowed in a flat file, in an app's entry and in `defaults`. A value in `defaults` serves the whole project, and an app's own value replaces it (ADR-0014, section 1):

| Key | What it is, and what the loader checks |
| --- | --- |
| `build_name` | The version (`CFBundleShortVersionString`). `build` gives it to Flutter as `--build-name`, instead of the part of `pubspec.yaml`'s `version` before `+`, so that the App Store version can run ahead of the Android one. It is one to three whole numbers joined by dots, the shape that Apple takes and that `preflight` already reads (`^\d+(\.\d+){0,2}$`) |
| `target` | The Dart entry point, which `build` gives to Flutter as `--target`. It is a path in the project under `lib/`, ending in `.dart`, of at most 64 characters: letters, digits, `.`, `_`, `-` and `/`, with no `..` part. The default is Flutter's own, `lib/main.dart` |
| `flutter_version` | The Flutter release that builds the app, as `flutter/flutter` tags it: `3.47.7`, or a pre-release such as `3.48.0-0.1.pre`. The workflow clones exactly that tag. Three whole numbers joined by dots, optionally followed by `-` and letters, digits and dots, at most 32 characters |
| `min_xcode_version` | The oldest Xcode that may build the app, such as `"26.0"`, since App Store Connect refuses builds made with an older one. The workflow stops when its Xcode is older. One to three whole numbers joined by dots. It must be quoted: YAML reads `26.0` as a number, which the loader refuses with a message that says to quote it |

- **`flutter_version` and `min_xcode_version` are needed by `build` and `doctor --build` only,** so `init`, `sign`, `preflight` and `upload` work without them. When one is missing, the build stops with `flutter-version-missing` or `min-xcode-missing` (78). Both go to the workflow as inputs (section 8), so each app of one workflow builds with its own values.
- **The version comes from,** in this order: `--build-name`; the app's `build_name`; `build_name` in `defaults`; `pubspec.yaml`'s `version` at the ref. If none of them gives one, the build stops with `build-name-missing` (78).
- **`flavor`** stays as ADR-0014 defines it, but the workflow now takes it as an input (section 8) instead of a value under `env`.
- **`configuration`** is now also read by `build`, for the check below. ADR-0014 said "Read by `init` only". It is not sent to the workflow: `flutter build ipa` has no option for the Xcode configuration, and derives it from the flavor.
- **There is no key for the build number,** since it changes with every build (section 3).
- **No `--dart-define`, and no free-form arguments.** Each input has a fixed meaning, and `flutter build ipa` takes it as an option of its own: `--flavor`, `--target`, `--build-name`, `--build-number`. A project that keeps each flavor's values in its own files needs nothing more.

  A workflow that a user has changed can still take more values through `workflow_inputs` (ADR-0014), which the reference workflow does not read. `build_name`, `target`, `flutter_version` and `min_xcode_version` join the input names reserved there. `build` sends seven inputs of its own, so `workflow_inputs` holds at most 18 entries, and a dispatch stays within GitHub's limit of 25 inputs.
- **A DEV variant and a store variant of one app are two apps,** each with its own bundle ID. App Store Connect sees them the same way: each has its own app record and its own build numbers.

  ```yaml
  defaults:
    team_id: TEAM000001
    credentials: team-one
    workflow: example-org/example-app/.github/workflows/wincode-ios.yml@main
    flutter_version: 3.47.7
    min_xcode_version: "26.0"
    build_name: 2.4.0
  apps:
    alpha:
      bundle_id: com.example.alpha
      flavor: store
      target: lib/main_store.dart
    alpha-dev:
      bundle_id: com.example.alpha.dev
      flavor: dev
      target: lib/main_dev.dart
      build_name: 2.5.0
  ```

  Variants that share one bundle ID are not supported, as decided in review: ADR-0014's refusal of a repeated bundle ID stays. A DEV flavor that testers get through TestFlight has its own bundle ID, and so its own app record.

**`build` checks the project at the ref's commit before the dispatch,** through GitHub's API. It checks that commit because that is what the runner builds. The local checkout may be on another branch, may hold changes that were never pushed, or may not exist at all on a server.

| What | The rule | When it does not hold |
| --- | --- | --- |
| Version and number | `pubspec.yaml` at the commit gives the version when nothing else does, and the build number in a flat file when no option does | `build-name-missing`, `build-number-missing` (78) |
| Target | The file exists at the commit | `target-missing` (78) |
| Flutter | When `pubspec.yaml` at the commit sets `environment: flutter:`, that constraint allows `flutter_version`, by pub's rules for version constraints | `flutter-version-mismatch` (78) |
| Flutter tag | `flutter/flutter` has a tag named `flutter_version`. One read, `GET /repos/flutter/flutter/git/ref/tags/{flutter_version}`, with the same token: the repository is public, and the host is the one the token goes to. The workflow clones that tag, and `git clone` fails on one that does not exist, at the job's second step, after a billed minute | `flutter-version-not-found` (78) |
| Xcode | The workflow's `XCODE_APP` at the commit names its version, as GitHub's runner images name each Xcode (`/Applications/Xcode_<version>.app`). That version is not older than `min_xcode_version` | `xcode-too-old` (78). A WARN when `XCODE_APP` names no version, such as `/Applications/Xcode.app`: the job then checks it, as its first step |
| Scheme | flutter_tools 3.47 builds the scheme named after the flavor with its first letter in capitals (`store` gives `Store`), or `Runner` when there is no flavor. If no scheme has exactly that name, it takes the one scheme that matches it ignoring case. The scheme must be a shared scheme of `ios/Runner.xcodeproj` (`xcshareddata/xcschemes/`). A scheme kept only in someone's `xcuserdata` is not in the repository, so the runner does not have it | `scheme-missing` (78) |
| Configuration | flutter_tools 3.47 builds `Release-<Scheme>`, matched ignoring case. Failing that, it builds the one configuration whose name holds both `Release` and the scheme. If none does, it builds `Release`; if several do, it stops. The configuration it would build must be the app's `configuration`, ignoring case; the default is `Release-<flavor>` | `configuration-mismatch` (78). The message says so when Flutter would fall back to `Release` |
| Bundle ID | The configuration's `PRODUCT_BUNDLE_IDENTIFIER` must be `bundle_id`. It is read with `wincode_core`'s reader, as `init` reads it | `bundle-id-mismatch` (1, ADR-0013's id). A WARN when it cannot be resolved, for example from an xcconfig file that is not committed |

- **A check fails only on a definite finding.** When winCode cannot read something, it gives a WARN, and the IPA's checks after the run (section 6) still apply. Two examples: a listing that GitHub truncates, and a file over GitHub's size limit.
- **Requests,** one each:
  - the commit (`GET .../commits/{ref}`);
  - its whole tree in one listing (`GET .../git/trees/{sha}?recursive=1`), which shows the shared schemes and whether the target exists;
  - `project.pbxproj`, each xcconfig file under `ios/`, `pubspec.yaml`, and the workflow file (section 8), read raw through the Contents API at that commit;
  - the Flutter tag (`GET .../git/ref/tags/{flutter_version}` of `flutter/flutter`).
- **`wincode_core`'s build-settings reader gets a parameter** that reads a file by its path, from the local disk by default. `init` and `build` then resolve settings with the same reader.
- **Pub's rules for version constraints** come from `pub_semver`, the Dart team's package (BSD-3-Clause). It is already in the CLI's lock file through `test`, and becomes a direct dependency, pinned exactly, in implementation pull request 3.
- **Two things are not checked before the dispatch:**
  - `pubspec.yaml`'s Dart constraint (`environment: sdk:`), which would need the Dart version of each Flutter release. `flutter pub get` on the runner refuses a mismatch within the job's first minutes;
  - whether the runner image has the Xcode that `XCODE_APP` names. `xcode-select` fails at the job's first step.
- **The scheme and configuration rules are those of flutter_tools 3.47.** If the release that `flutter_version` names has other rules, the IPA's bundle ID check after the run still catches a wrong build, and winCode's rules are updated when Flutter changes them.
- **The Flutter project is at the repository's root,** where the reference workflow builds it.

### 3. The build number

| Option | For | Against |
| --- | --- | --- |
| A. Always given on the command line | Nothing is hidden | Every caller has to look up the highest number first |
| B. Always `auto` | No bookkeeping | It needs the App Store Connect key in a step that otherwise needs none, and it cannot work with build numbers that contain dots |
| **C. `auto` by default in a file of apps, `pubspec.yaml`'s number by default in a flat file, and `--build-number <n>` or `--build-number auto` to choose** (chosen) | In a file of apps, `pubspec.yaml`'s number may be another platform's and fits no app's sequence, while every app has the credentials that `auto` needs (ADR-0014). A one-app flat project works as it does by hand. In every case the number is decided before the dispatch | Two defaults to explain |

**C is chosen,** with `auto` as the default of a file of apps since the review. Whatever its source, the number is decided before the dispatch and sent as the `build_number` input, and the plan says where it came from. When there is no source, the build stops with `build-number-missing` (78): a flat file, no option, and a `version` in `pubspec.yaml` without `+N`.

**`auto` gives the highest number known for the app, plus one.** It looks in two places:
- **App Store Connect:** the app's builds, read with `preflight`'s GET requests and the app's credentials (ADR-0014, section 2). It also reads the app's build uploads, if `GET /v1/apps/{id}/buildUploads` exists; the implementation checks that first. An upload that Apple has not yet turned into a build holds its number too.
- **The app's recent runs** (below).

The highest number must be a whole number. A highest number with dots, such as `57.1`, fails `auto` with `build-number-auto` (1): winCode does not guess the next step of someone else's numbering scheme. In a flat file without credentials, `auto` fails with `credentials-missing` (78); in a file of apps, every app has them.

**A number given on the command line, or taken from `pubspec.yaml`, is checked the same way** when the app has credentials. If it is not above the highest, the build stops with `build-number-not-higher` (1, ADR-0013's id) before any minute is spent on a build that `upload` would refuse. Without credentials, the check is a WARN, and `preflight` checks the number before the upload, as today.

**Two builds of one app at once.** App Store Connect learns a number only when the IPA is uploaded, after `sign`, minutes after the run. Until then the number lives only in the run, so the run carries it in its name:

- **The request ID** is `<app tag>-<version>-<build number>-<random>`, for example `3f9a0c1d2b4e-2.4.0-58-7c21e0aa`. The run's name stays `wincode <request_id>`.
  - The app tag is the first 12 hex digits of the SHA-256 of the bundle ID in lower case. The bundle ID ties the run to the app record, whichever file or machine started the run, and hashing it keeps the app's name and bundle ID out of the run list.
  - The random part is 8 hex digits.
- **Before the dispatch,** `build` lists the workflow's dispatched runs of the last 24 hours (`GET .../actions/workflows/{file}/runs?event=workflow_dispatch&created=>=<time>`). It reads the tag, version and number from each run's name, and ignores names of any other shape.
- **A queued or running build of the same app** stops this one with `build-in-progress` (1), which links that run. The next step is to collect that run with `--run <id>`, or to cancel it on GitHub.
- **A successful run of the same app** holds its number. `auto` goes above it, and a given number that is not above it is refused, as above. A run that ended any other way made no IPA, so its number is free.
- **One gap remains.** Two machines can dispatch builds of one app within the same few seconds. Neither finds the other's run, so both can take the same number, and both builds run.
  - The second upload is then refused, by `preflight` (number not higher) or by Apple (`upload-refused`). Nothing wrong reaches App Store Connect; the cost is one build.
  - Closing the gap would need a lock in a place both machines can write, which winCode does not have. ADR-0014 leaves locks out of scope.

**How `preflight` and `upload` see the same number:** the IPA carries it.
- The workflow passes `--build-name` and `--build-number` to `flutter build ipa`, which writes them into `Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`).
- After the download, `build` checks that the IPA holds exactly the version and number it asked for (`ipa-version-mismatch`, 1).
- `sign` changes neither.
- `preflight` and `upload` read both from the IPA, as they do today.

There is no state file: the IPA is the record, and `build`'s result gives both numbers to a caller.

### 4. Starting and following the run

**`build` talks to GitHub's REST API from Dart,** through `dart:io`, with no new dependency. Every request goes to `https://api.github.com` with the header `X-GitHub-Api-Version: 2026-03-10`.

1. **Dispatch.** `POST /repos/{owner}/{repo}/actions/workflows/{file}/dispatches` with `ref` and `inputs`. The answer is 200, with `workflow_run_id`, `run_url` and `html_url`.

   The dispatch is never sent twice: if its answer is lost, the run may or may not exist, and a second request could start a second paid run. The build then stops with `offline` (69). The message says to look for the run named `wincode <request_id>` on the workflow's page, and to collect it with `--run <id>`.
2. **Check that the run is ours.** `GET .../actions/runs/{id}`, read again every 5 seconds for up to 2 minutes until GitHub shows the run. Its `display_title` must be `wincode <request_id>`, and its `event` must be `workflow_dispatch`; otherwise, after those 2 minutes, `run-not-found` (1), whose message says which name the run had.

   **A name that is not ours yet is waited for.** Right after a dispatch, GitHub shows the run under the name of the workflow (`wincode-ios`), and under the name that `run-name` gives it only a moment later: the real check of part 5b saw it, and the first version of `build` took the first name for another run. The dispatch's answer names the run, so only the 2 minutes can make it a failure.

   An answer without a run ID (204, as the previous API version answers) falls back to ADR-0013's search: list the workflow's dispatched runs every 5 seconds, for up to 2 minutes, until one has that name.
3. **Its commit.** The run's `head_sha` must be the commit that section 2 checked, which `build` recorded when it read the ref. If the branch (or the tag) moved between the checks and the dispatch, the checks were made on one commit and the runner builds another: the scheme, the configuration, the bundle ID and the other checks say nothing about it. The build then stops with `ref-moved` (1), as soon as the run is known:
   - it downloads nothing, and it does not wait for the run;
   - it does not cancel the run: only the person does that. The message names both commits and links the run, and the result holds the run's ID and address, so that the person or a calling tool can cancel it;
   - running `build` again checks the new commit and builds it.

   Only a run that `build` started has this check. `--run` collects a run whose commit nobody recorded, and the IPA's checks still apply to it.
4. **Wait.** Every 30 seconds, `build` reads the run (`GET .../actions/runs/{id}`) and, once it has started, its jobs (`GET .../actions/runs/{id}/jobs`), for the status of each job and step.
   - **Requests:** each poll sends the previous answer's `ETag`. A 304 answer means nothing changed, and GitHub does not count it against the primary rate limit. A build makes at most about 240 requests an hour, against 5,000 for a personal token, so one token follows about 20 builds at once even without the 304s.
   - **Rate limits:** `build` obeys `retry-after` and `x-ratelimit-reset`. A rate limit slows the polling; it does not fail the build.
   - **Failed reads** are retried with a bounded backoff, as `upload`'s reads are: a read changes nothing.
5. **End.** A run that ends in `success` goes on to the artifact (section 6). A cancelled run is `run-cancelled` (1). Any other ending is `run-failed` (1). Its message names the first step that failed, from the jobs. If the job has no steps, the message says the job never started (as when the account's spending limit is reached), and the run's page says why.

**No automatic re-run.** A build that failed on the runner usually fails the same way again, and each attempt costs minutes. The message links the failed step's log, and running `build` again is the user's decision; a failed run's number is free again (section 3). winCode does not use GitHub's re-run either: a re-run keeps the run's ID and adds an attempt, and winCode follows the attempt it started.

**Ctrl-C:**
- **Before the dispatch is sent,** winCode stops as it does today. Nothing was started.
- **After it, at a terminal** (and without `--json` or `--events`), winCode asks: `Cancel the run on GitHub too? It has run for about <n> minutes. [y/N]`.
  - No is the default, also for Enter or a second Ctrl-C. The run goes on; winCode prints how to collect it and exits 75 (`wait-stopped`).
  - Yes sends `POST .../actions/runs/{id}/cancel`, and winCode exits 1 (`run-cancelled`).
- **With `--json` or `--events`, without a terminal, or on SIGTERM (Linux),** winCode asks nothing and cancels nothing, and exits 75 (`wait-stopped`). A calling tool that wants the run stopped cancels it itself: the run's ID is in the `dispatched` event. A `build` that is still waiting then reports `run-cancelled`.

winCode never cancels a run on its own: the minutes already spent are spent, and the build may still succeed.

**Timeout.** `--timeout` ends the wait, not the run: exit 75 (`run-timeout`), with `--run <id>` to collect the run later. The workflow's own `timeout-minutes`, 45 in the reference workflow, is what stops a run that hangs.

**`--run <id>`** collects a run that a `build` started and then stopped waiting for. The run must be a `workflow_dispatch` run of the app's workflow file, and its name must carry the app's tag; otherwise, `run-mismatch` (1). It skips the checks of sections 2 and 3, waits while the run is still going, and checks the IPA against the version and number in the run's name.

**At a terminal,** without `--json` or `--events`, the same progress goes to stderr for people: one line each time the run, a job or a step changes.

### 5. GitHub authentication

| Option | For | Against |
| --- | --- | --- |
| A. `gh`, as ADR-0013 planned | `gh` keeps the login, and winCode holds no token | `gh` is often missing on a server, and there it reads `GH_TOKEN` anyway: winCode would hand a token to another program instead of holding none. A calling tool needs jobs and steps as data, and `gh run watch` prints them for people. The run's URL comes back only "if available". How the redirect to the artifact store is followed is `gh`'s choice |
| **B. The REST API, with a token from the environment or from `gh`** (chosen) | One program on Windows and Linux. The dispatch returns the run's ID; jobs and steps arrive as data; winCode decides where the token goes | winCode holds a token in memory during the run, and must keep it out of every output |
| C. A GitHub App, or OAuth's device flow | Short-lived tokens | An app to register and install for each organisation, or a token to store and renew: far more than one command needs |

**B is chosen.** It reverses ADR-0013's section 3 and its alternative "The REST API instead of `gh`".

**winCode looks for the token in this order.** One token serves every app, and an app can have its own:
1. `WINCODE_GH_TOKEN_<APP>`, for the app being built, when it is set.
   - `<APP>` is the app's name in capital letters with `-` written as `_` (`alpha-dev` gives `ALPHA_DEV`), as ADR-0014 (section 2) names the variables of a credentials reference.
   - A flat file has no app name, so it has no such variable.
   - The variable form of every app's name is registered with the redactor, as a reference's is.
2. `GH_TOKEN`;
3. `GITHUB_TOKEN`;
4. `gh auth token --hostname github.com`, when `gh` is installed and logged in. A desktop user of `gh` needs nothing more.

Sources 2 to 4 come in the order in which `gh` itself reads them. When none gives a token, the build stops with `github-token-missing` (77). On a Linux server without `gh`, set `GH_TOKEN` in the service's environment, from the server's secret store, and `WINCODE_GH_TOKEN_<APP>` for an app whose repository needs another token.

**GitHub Enterprise Server is not supported,** as decided in review: the API host is always `api.github.com`, and `GH_ENTERPRISE_TOKEN` is not read.

**The least that the token needs** is a fine-grained personal access token limited to the app's repositories, with:
- **Actions: read and write,** to start a run, read runs, jobs and artifacts, cancel a run and delete an artifact;
- **Contents: read,** for the project and the workflow at the ref;
- **Metadata: read,** for the repository itself (`GET /repos/{owner}/{repo}`).

A classic token, and the token of `gh`'s login, need the `repo` scope, which can do much more. `doctor --build` says which kind of token it found.

**How winCode treats the token:**
- **It is never in `wincode.yaml`.** There is no key for it, and the loader already refuses keys that look like secrets, `token` among them.
- **It is never printed,** `--verbose` included: it is registered with the redactor as a secret as soon as it is read. Output names only its source and its kind (`GH_TOKEN, a fine-grained token`), which winCode tells apart by GitHub's prefixes (`github_pat_`, `ghp_`, `gho_`).
- **It is sent only to `https://api.github.com`.** Redirects are followed by hand, without the token. The artifact's download answers 302 with a signed link to GitHub's storage, on another host, that needs no token. GitHub's reference says that the link expires after 1 minute; in the rehearsal, the link's own parameters gave it 10 minutes (section 13). winCode follows it at once. That link is registered with the redactor too, and `--verbose` shows only its host.
- **It is held in memory for the run** and never written to a file.

**Refusals:**
- A 401 is `github-unauthorized` (77), and a 403 that is not a rate limit is `github-forbidden` (77).
- A 404 for the repository is `repository-not-found` (78). GitHub answers 404 for two reasons, and the message gives both: a misspelled `workflow:`, or a token that cannot see the repository.
- A token without Actions write is refused at the dispatch, before anything runs, so it costs no minute.

### 6. The artifact

**The workflow records the IPA's hash.** The artifact `unsigned-ipa` holds two files:
- `unsigned.ipa`;
- `unsigned.ipa.sha256`, the SHA-256 that the build job computes (`shasum -a 256`) right after it packs the IPA.

The job also writes the hash into its step summary, on the run's page. Retention stays 1 day.

**Download and checks.** They happen in a folder `.wincode-build-<random>` in the app's output folder, as `sign` does, and the folder is deleted at the end whatever happens.
1. **One artifact.** The run must have exactly one artifact named `unsigned-ipa`, and it must not have expired. Otherwise, `artifact-missing` (1, ADR-0013's id), which says when it expired.
2. **Download.** `GET .../actions/artifacts/{id}/zip` answers 302. winCode follows the redirect without the token and streams the zip to disk.
3. **Transfer.** The artifact's `digest` is `sha256:` and the SHA-256 of the zip as it downloads, and the zip's SHA-256 must equal it (`artifact-integrity`, 1).
   - GitHub's reference does not say what `digest` covers. The rehearsal showed that it is the zip's, with the same value as `upload-artifact`'s output `artifact-digest` (section 13).
   - An artifact without a `digest`, or with another form, gives an INFO line, not a check.
4. **Content.** The zip must hold `unsigned.ipa` and `unsigned.ipa.sha256` and nothing else (`artifact-content`, 1). The IPA's SHA-256 must be the recorded one (`artifact-integrity`, 1).

   The two hashes cover different paths. `digest` comes in the API's answer and covers storage and transfer. The recorded hash covers the file from the build job to this disk, and the step summary shows it to a person.
5. **The IPA.** The checks of ADR-0013's step 6: one `Payload/<name>.app`, whose bundle ID is `bundle_id`, and no `embedded.mobileprovision`. Its version and build number must also be the ones requested (`ipa-version-mismatch`, 1).
6. **Move.** The IPA replaces `<output>/unsigned.ipa` only once every check has passed. `signed.ipa` is left alone.

`wincode_core`'s zip reader opens both archives. It refuses Zip64, which neither archive needs at these sizes; the rehearsal showed that it opens GitHub's zip and the IPA inside it (section 13). Its `read` keeps at most 64 MB of an entry in memory, and an IPA can be larger, so the reader gets a method that streams an entry to a file, for the IPA.

**Public repositories:**

| Option | For | Against |
| --- | --- | --- |
| A. Build anyway; the reference workflow's comment only warns today | Nothing to type | Anyone with a GitHub account can download the app's IPA for a day |
| B. Refuse | Nothing leaks | Standard runners cost nothing in a public repository, whose code is public anyway |
| **C. Refuse unless `--allow-public`, and with it delete the artifact as soon as it has been checked** (chosen) | The user decides each time, in writing. The IPA is downloadable for minutes, not a day | It is still downloadable during those minutes |
| D. Encrypt the IPA on the runner | The IPA stays private even in a public repository | It needs a key on the runner, as a repository secret. Rejected in review |
| E. With `--allow-public`, delete the whole run too | The log and the inputs go as well | They hold no secret, and the artifact is the one copy of the IPA. Rejected in review |

**C is chosen, and kept after review.**
- The repository's visibility comes from `GET /repos/{owner}/{repo}`.
- A public repository without the flag stops the build with `repository-public` (64), before the dispatch.
- With the flag, `DELETE .../actions/artifacts/{id}` follows the checks. If the delete fails, a WARN says that the IPA stays downloadable until it expires, and links the run.
- A private or internal repository keeps the artifact for its day, so that `--run` can download it again.
- In every case, the run's log and inputs stay on its page, and they hold no secret.

**The runner still needs no Apple secret.** The reference workflow reads no secret at all and signs nothing (`--no-codesign`), and `build` refuses an IPA that carries a profile. A user's copy of the workflow could add secrets: the template's comments say not to, and the contract check (section 8) does not look for them.

### 7. Cost guard

- **`--dry-run` keeps ADR-0013's meaning: it sends no request at all.**
  - It prints the plan below from `wincode.yaml` and the options, and the dispatch request as it would go out.
  - Values that only GitHub or Apple can give are placeholders: `<commit of main>`, `<auto: App Store Connect's highest + 1>`, `<pubspec.yaml at main>`.
  - `--json` gives the same as an object.
- **`wincode doctor --build`** (section 10) runs every read-only check that `build` makes before a dispatch, with the real values, and starts nothing.
- **The plan and the question.** After its read-only checks and before the dispatch, `build` prints its plan and asks:

  ```
  Build plan:
    app:         alpha (com.example.alpha)
    repository:  example-org/example-app, private: the account pays for the minutes
    workflow:    .github/workflows/wincode-ios.yml, contract 2, as winCode's template
    ref:         main, commit 1a2b3c4
    runner:      macos-26, stopped after 45 minutes (timeout-minutes)
    xcode:       26.6 (XCODE_APP), at least 26.0 (min_xcode_version)
    flutter:     3.47.7 (flutter_version), allowed by pubspec.yaml
    flavor:      store, scheme Store, configuration Release-store
    target:      lib/main_store.dart
    version:     2.4.0 (build_name in wincode.yaml)
    build:       58 (auto: App Store Connect's highest is 57; no run of alpha in the last 24 hours)
  Start this build on GitHub? It uses macOS minutes. [y/N]
  ```

  - The question is y/N, as decided in review: a build spends money, but it takes nothing that cannot be given back. `upload` keeps its typed app name.
  - Any answer but `y` or `yes` starts nothing: `build-cancelled` (1), like `upload-cancelled`.
  - `--yes` skips the question.
  - Without a terminal, with `--json` or `--events`, or in CI, a missing `--yes` is `confirmation-required` (64), before any request, as for `upload`.
- **What a caller sees of the cost:**
  - the `plan` event and the result carry the runner's label (`runsOn`), the workflow's `timeoutMinutes`, and whether the repository is `private`;
  - a `wait` event every 60 seconds carries the minutes so far;
  - the result's `minutes` gives each job's time, from its `started_at` and `completed_at`, rounded up per job, as an estimate.
- **Cost is shown in minutes only,** as decided in review. winCode shows no prices and reads no billing data: prices and included usage depend on the account's plan. GitHub's timing endpoints are being closed down, and they leave the macOS multiplier out.

### 8. Template drift

**The workflow states its contract** in a line `# wincode-workflow-contract: 2`. The number counts what `build` relies on: the inputs and their meaning, the run's name, and the artifact's name and files. It changes only when one of those changes; versions, steps and comments can change without it. Contract 1, the template before part 5c, had no such line, and a workflow without it counts as contract 1.

**Before the dispatch,** `build` reads the workflow file at the ref's commit:
- **Another contract number, or none:** `workflow-contract` (78), and nothing starts.
  - A contract 1 workflow does not declare the inputs that contract 2 adds, and GitHub refuses a dispatch with inputs that the workflow does not declare.
  - The message gives both numbers. The next step is `wincode init --workflow`, which updates the workflow (below), or a newer winCode when the workflow is the newer one.
- **The same contract, with other parts changed:** one WARN (`workflow-differs`) that names the parts that differ from winCode's template. The two files are compared as parsed YAML, so a comment, a blank line, the order of keys and the text of an input's `description` are never differences, and neither are the values that a user is expected to set: `XCODE_APP`, `runs-on` and `timeout-minutes`. An action's pin is not ignored: a bumped pin names its step. Part 5c settled the naming (see "As built: part 5c").
  - `--verbose` prints the differing lines, with `init`'s `diffLines`.
  - The build goes on: a changed workflow belongs to its owner, and the contract and the IPA's checks still hold.
- **The file itself:**
  - `GET .../actions/workflows/{file}` must find it (`workflow-not-found`, 78): GitHub dispatches only a workflow that is on the default branch.
  - Its `state` must be `active` (`workflow-disabled`, 78).
  - A 422 from the dispatch for an input is `workflow-input-unknown` (78), as ADR-0014 planned.
  - GitHub runs the workflow file as it is at the dispatched ref, and checks the dispatch's inputs against that copy, which is the copy winCode checked. The rehearsal showed both (section 13).

**`build` never writes to the app's repository.** It reads the workflow and says what differs.

**`init --workflow` updates the workflow, and only when the user runs it** (decided in review):
- with no workflow file, it writes the reference workflow, as today;
- with one, it prints the diff between that file and the reference workflow, in which the old file's `XCODE_APP`, `runs-on` and `timeout-minutes` are kept. Then it asks at a terminal, or takes `--yes` where it cannot ask; otherwise it stops with `init-input-missing` (64) and writes nothing;
- before writing, it copies the old file byte for byte to `wincode-ios.yml.bak` next to it. GitHub runs only `.yml` and `.yaml` files, so the backup never runs. An existing `.bak` stops it (`backup-exists`, 1) unless `--force` is given, as in ADR-0014's migration (section 5);
- `--dry-run` prints the diff and writes nothing;
- when `wincode.yaml` exists, `init --workflow` changes the workflow, and in `wincode.yaml` only adds `flutter_version`, taken from the old workflow's `FLUTTER_VERSION`, when it has none; it needs no `--app`;
- committing and pushing the new file stays the user's step.

This replaces ADR-0013's rule that `init` never replaces the workflow file.

**Contract 2 changes the reference workflow in these ways:**
- it adds the contract line;
- it takes the inputs `request_id`, `build_name`, `build_number`, `flutter_version` and `min_xcode_version` (required) and `flavor` and `target` (optional, empty by default), all strings. `FLUTTER_VERSION` and `FLAVOR` leave `env`; `XCODE_APP` stays there, as the choice of an Xcode that the runner image has;
- inputs reach the shell only as environment variables of their steps (`MIN_XCODE_VERSION`, `FLUTTER_VERSION`, `BUILD_NAME`, `BUILD_NUMBER`, `FLAVOR`, `TARGET`), never as `${{ inputs.* }}` inside `run:`, so that no input is ever read as shell code;
- the Xcode step stops the job when the Xcode it selected is older than `min_xcode_version`;
- the Flutter step clones the tag `flutter_version`;
- the build passes `--build-name` and `--build-number`, and `--flavor` and `--target` when they are set;
- it writes the hash file, and the hash in the step summary;
- the artifact holds both files.

The parts that change:

```yaml
# wincode-workflow-contract: 2
name: wincode-ios
run-name: wincode ${{ inputs.request_id }}

on:
  workflow_dispatch:
    inputs:
      request_id:
        description: Set by wincode build, which finds this run by it
        required: true
        type: string
      build_name:
        description: The version (CFBundleShortVersionString), x.y.z
        required: true
        type: string
      build_number:
        description: The build number (CFBundleVersion)
        required: true
        type: string
      flutter_version:
        description: The Flutter release, a tag of flutter/flutter
        required: true
        type: string
      min_xcode_version:
        description: The oldest Xcode that may build the app
        required: true
        type: string
      flavor:
        description: The flavor, or empty for an app without flavors
        required: false
        type: string
        default: ""
      target:
        description: The entry point, or empty for lib/main.dart
        required: false
        type: string
        default: ""

# (permissions, the job and checkout as in contract 1; env keeps XCODE_APP only)

      - name: Xcode
        env:
          MIN_XCODE_VERSION: ${{ inputs.min_xcode_version }}
        run: |
          sudo xcode-select -s "$XCODE_APP"
          xcodebuild -version
          have=$(xcodebuild -version | sed -n 's/^Xcode //p')
          if ! awk -v have="$have" -v min="$MIN_XCODE_VERSION" 'BEGIN {
            n = split(have, h, ".")
            m = split(min, w, ".")
            if (m > n) n = m
            for (i = 1; i <= n; i++) {
              if (h[i] + 0 > w[i] + 0) exit 0
              if (h[i] + 0 < w[i] + 0) exit 1
            }
            exit 0
          }'; then
            echo "::error::Xcode $have is older than $MIN_XCODE_VERSION, the oldest that wincode.yaml allows"
            exit 1
          fi

      - name: Flutter
        env:
          FLUTTER_VERSION: ${{ inputs.flutter_version }}
        run: |
          git clone -q --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$RUNNER_TEMP/flutter"
          echo "$RUNNER_TEMP/flutter/bin" >> "$GITHUB_PATH"

      - name: Build the archive, unsigned
        env:
          BUILD_NAME: ${{ inputs.build_name }}
          BUILD_NUMBER: ${{ inputs.build_number }}
          FLAVOR: ${{ inputs.flavor }}
          TARGET: ${{ inputs.target }}
        run: |
          args=(--release --no-codesign --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER")
          if [ -n "$FLAVOR" ]; then args+=(--flavor "$FLAVOR"); fi
          if [ -n "$TARGET" ]; then args+=(--target "$TARGET"); fi
          flutter build ipa "${args[@]}"

# (the packing step as in contract 1, which then ends with:)
          (cd "$RUNNER_TEMP" && shasum -a 256 unsigned.ipa | tee unsigned.ipa.sha256)
          echo "unsigned.ipa SHA-256: $(cut -d ' ' -f 1 "$RUNNER_TEMP/unsigned.ipa.sha256")" >> "$GITHUB_STEP_SUMMARY"

      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        with:
          name: unsigned-ipa
          path: |
            ${{ runner.temp }}/unsigned.ipa
            ${{ runner.temp }}/unsigned.ipa.sha256
          if-no-files-found: error
          retention-days: 1
```

### 9. Progress for a calling tool, and exit codes

**`--json` is unchanged:** one object on stdout when `build` ends.

**`--events`,** for `build`, `sign` and `upload` (`sign` and `upload` since the review), writes one JSON object per line on stdout, as things happen.
- Its last line is the same object that `--json` gives, with `"event": "result"` added.
- `--events` and `--json` together are a usage error (64), so that stdout always has one shape.
- Text for people goes to stderr in both cases.
- A command that asks a question needs `--yes` with `--events`, as with `--json`: `build`, and `upload` for its typed name.

Each event has `event`, `time` (UTC, ISO 8601) and `app`. `app` is the app's name, its placeholder when redaction is on, or null for a flat file.

| `event` | When | Its other fields |
| --- | --- | --- |
| `check` | each check before the dispatch | `id`, `status` (`PASS`, `WARN`, `FAIL` or `INFO`, as in `preflight`), `text` |
| `plan` | before the dispatch | `repository`, `private`, `workflow`, `ref`, `commit`, `runsOn`, `timeoutMinutes`, `inputs`, `buildName`, `buildNumber`, `buildNumberSource` |
| `dispatched` | once the run exists | `requestId`, `runId`, `runUrl` |
| `run` | the run's status changes | `status`, `conclusion` |
| `job`, `step` | a job or a step starts or ends | `job`; and for a step `number`, `name`, `status`, `conclusion` |
| `wait` | every 60 seconds | `status`, `elapsedSeconds`, `minutes` |
| `artifact` | the artifact is downloaded | `name`, `size`, `digest`, `expiresAt` |
| `ipa` | the IPA passed its checks | `path`, `size`, `sha256`, `bundleId`, `version`, `build` |
| `result` | last | the `--json` object |

`sign` and `upload` use the same envelope and the same `check`, `wait` and `result` events, plus their own:

| Command | Its own events |
| --- | --- |
| `sign` | `signing` when zsign starts and when it ends (`status`). Its `check` events cover the inputs before signing and the read-back of every signature after |
| `upload` | `plan`, the upload it is about to make (file, size, version, build); `upload` at each stage (`created`; the parts, with `sentBytes` and `totalBytes`; `committed`); `processing` at each change of Apple's state, with Apple's messages as sent. Its `check` events are the findings of its `preflight` |

```json
{"event":"dispatched","time":"2026-11-15T10:02:11Z","app":"alpha","requestId":"3f9a0c1d2b4e-2.4.0-58-7c21e0aa","runId":1234567890,"runUrl":"https://github.com/example-org/example-app/actions/runs/1234567890"}
{"event":"step","time":"2026-11-15T10:04:40Z","app":"alpha","job":"unsigned-ipa","number":5,"name":"Build the archive, unsigned","status":"in_progress","conclusion":null}
{"event":"wait","time":"2026-11-15T10:05:11Z","app":"alpha","status":"in_progress","elapsedSeconds":180,"minutes":3}
```

**The result object** has these fields:
- `command`, `app`, `ok`, `exitCode`;
- `repository`, `workflow`, `ref`, `commit`;
- `requestId`, `runId`, `runUrl`, `conclusion`;
- `buildName`, `buildNumber`;
- `ipa`: `path`, `size`, `sha256`, `bundleId`, `version`, `build`;
- `minutes`: `total`, and `jobs`, each with `name`, `runsOn`, `seconds` and `minutes`;
- `checks`;
- `error`, on a failure.

A field that is not known yet is null: for example `runId`, when a check failed before the dispatch.

**Stability is as ADR-0014 (section 7) says.**
- A field or an event is not renamed, removed or given another type without an amendment.
- New fields and events may be added, and a reader ignores what it does not know.
- Everything passes through the redactor, with `--redact` and in CI too.

**Exit codes: no new number.** ADR-0013's table gets these meanings for `build`:

| Code | For `build` |
| --- | --- |
| 0 | `<output>/unsigned.ipa` holds the run's IPA, and it passed every check |
| 1 | One of five things. A check before the dispatch failed, so nothing started (`build-in-progress`, `build-number-not-higher`, `bundle-id-mismatch`, …). The run failed or was cancelled. The run builds another commit than the one that was checked (`ref-moved`), and goes on. The artifact or the IPA failed a check. Or the question was answered no |
| 64 | The command line (`--all`, a commit SHA as `--ref` (`ref-is-commit`), `--run` with `--ref`, `--events` with `--json`), `confirmation-required`, or `repository-public` |
| 69 | GitHub or App Store Connect cannot be reached before the dispatch, or the dispatch's answer was lost (`offline`), GitHub is down (`github-unavailable`) or limits the token for longer than winCode waits (`github-rate-limited`) |
| 70 | A bug |
| 75 | A run was started, or named with `--run`, and was still going when winCode stopped waiting: at `--timeout` (`run-timeout`), or after Ctrl-C (`wait-stopped`). Collect it with `--run <id>` |
| 77 | No GitHub token, or GitHub refused it (401, or a 403 that is not a rate limit). Or App Store Connect refused the key, when `build` reads it |
| 78 | The setup: no `workflow:`, `repository-not-found`, `ref-not-found`, `workflow-not-found`, `workflow-disabled`, `workflow-contract`, `workflow-input-unknown`, `scheme-missing`, `configuration-mismatch`, `target-missing`, `build-name-missing`, `build-number-missing`, `credentials-missing`, `flutter-version-missing`, `min-xcode-missing`, `flutter-version-mismatch`, `flutter-version-not-found`, `xcode-too-old`, and, named while building part 5a, `workflow-input-missing`, `workflow-unreadable`, `project-not-found` and `github-token-invalid` |

75 was "`upload` only" in ADR-0013, and is now `upload` and `build`.

### 10. `doctor --build`

`wincode doctor --build [--app <name> | --all]` makes, for each app, every check that `build` makes before a dispatch, and starts nothing.
- Because it only reads, `--all` is allowed, with the table and exit code of ADR-0014 (section 3).
- `build` runs the same checks before every dispatch, so `doctor --build` is a preview, not a step that `build` needs.

| Check | What it shows | Result |
| --- | --- | --- |
| Settings | `workflow:`, `flutter_version` and `min_xcode_version` are there and well formed; `flavor`, `target` and `build_name` are valid | FAIL (78) |
| Token | Where it comes from (the app's `WINCODE_GH_TOKEN_<APP>`, `GH_TOKEN`, `GITHUB_TOKEN` or `gh`), and its kind | FAIL `github-token-missing`. INFO for a classic token or `gh`'s login, which can do more than `build` needs |
| Repository | It can be read; its visibility and default branch | FAIL `repository-not-found`. WARN when it is public: `build` will need `--allow-public` |
| Workflow | It is on the default branch, and active | FAIL `workflow-not-found`, `workflow-disabled` |
| Ref | The commit it points to | FAIL `ref-not-found` (78) |
| Contract | The workflow at that commit has contract 2 | FAIL `workflow-contract`; WARN for other differences |
| Project | The checks of section 2 at that commit, the Flutter release and the workflow's Xcode among them | As in section 2 |
| Build number | The number that `build` would take, where it comes from, and any run of this app in progress | As in section 3. INFO when the app has no credentials |

An INFO line says that Actions write is not tested ahead. Every request that needs it changes something; the dispatch itself refuses a token without it, before anything runs.

### 11. Platforms

`build` and `doctor --build` are pure Dart over HTTPS. They need no WSL2, no `gh` and no Mac on the machine that runs `wincode`, and they work the same on Windows and Linux. The tests run on both (ADR-0013, section 8).

A Linux server sets `GH_TOKEN` in the service's environment, and passes `--yes`, plus `--events` or `--json` for the calling tool. Ctrl-C uses Dart's `ProcessSignal.sigint`, which works on both systems; SIGTERM is watched on Linux only.

### 12. Messages

All messages use the three-line form of ADR-0013 (section 6).

1. **Contract** (`workflow-contract`, 78):

   ```
   wincode build: the workflow at main says contract 1, and this wincode needs contract 2
     why: contract 2 adds inputs, such as build_name and flutter_version, that a contract 1 workflow does not declare, and GitHub refuses a run with inputs that its workflow does not declare. Nothing was started.
     next: run wincode init --workflow, which shows the changes and keeps the old file as wincode-ios.yml.bak, then push the workflow to main and run wincode build again.
   ```

2. **Configuration fallback** (`configuration-mismatch`, 78):

   ```
   wincode build: flavor store builds the configuration Release, not Release-store
     why: Flutter builds the configuration named after the flavor's scheme (Store), and when the project has none it builds Release without an error, so the IPA would carry Release's bundle ID and settings. Nothing was started.
     next: add a configuration Release-store to ios/Runner.xcodeproj and push it, or set configuration in wincode.yaml to the configuration that this flavor really uses.
   ```

3. **Public repository** (`repository-public`, 64):

   ```
   wincode build: example-org/example-app is a public repository
     why: anyone with a GitHub account can download a run's artifacts until they expire, so the app's IPA would be public. Nothing was started.
     next: build from a private repository, or give --allow-public; winCode then deletes the artifact as soon as it has downloaded and checked it.
   ```

4. **Failed run** (`run-failed`, 1):

   ```
   wincode build: run <URL> failed at step "Build the archive, unsigned"
     why: the step's log says why. A build that fails on the runner usually fails the same way again, so winCode does not start it again.
     next: read the log at <URL>, fix the cause and push it, then run wincode build again. Build number 58 was not used.
   ```

5. **Stopped waiting** (`wait-stopped`, 75):

   ```
   wincode build: stopped waiting for run <URL>, which is still running
     why: the run goes on and uses macOS minutes until it ends; its IPA can be downloaded for a day after that.
     next: run wincode build --app alpha --run <id> to wait for it and collect the IPA, or cancel it at <URL>.
   ```

6. **Integrity** (`artifact-integrity`, 1):

   ```
   wincode build: the IPA in the artifact does not match the SHA-256 that the run recorded
     why: the file changed between the build job and this disk, and winCode does not sign an IPA it cannot trace to its run.
     next: download it again with wincode build --app alpha --run <id>; if the hashes still differ, build again.
   ```

7. **No token** (`github-token-missing`, 77). When `gh` is installed but not logged in, the first line says so.

   ```
   wincode build: no GitHub token: WINCODE_GH_TOKEN_ALPHA, GH_TOKEN and GITHUB_TOKEN are not set, and gh is not installed
     why: winCode starts the workflow through GitHub's API, which needs a token with Actions (read and write) and Contents (read) on the repository.
     next: set GH_TOKEN to a fine-grained token limited to example-org/example-app with those permissions (WINCODE_GH_TOKEN_ALPHA for this app only), or install gh and run gh auth login.
   ```

8. **Build in progress** (`build-in-progress`, 1):

   ```
   wincode build: a build of alpha is already running: <URL> (build 58)
     why: two runs of one app would compete for the same build number and the same output folder.
     next: collect it with wincode build --app alpha --run <id>, or cancel it at <URL>, then run wincode build again.
   ```

9. **Xcode too old** (`xcode-too-old`, 78):

   ```
   wincode build: the workflow selects Xcode 26.0, and wincode.yaml asks for 26.4 or later
     why: min_xcode_version is the oldest Xcode that may build alpha, and the job would stop at its Xcode step, after a billed minute. Nothing was started.
     next: set XCODE_APP in .github/workflows/wincode-ios.yml to an Xcode of 26.4 or later that the runner image has, push it to main, then run wincode build again.
   ```

10. **Flutter tag not found** (`flutter-version-not-found`, 78):

    ```
    wincode build: flutter/flutter has no tag 3.47.9
      why: the workflow clones that tag on the runner, and git fails at once on a release that does not exist, after a billed minute. Nothing was started.
      next: correct flutter_version in wincode.yaml: flutter --version prints the release, and the tags are listed at https://github.com/flutter/flutter/tags.
    ```

11. **Ref moved** (`ref-moved`, 1), added while building part 5b. The run exists and goes on; the message links it.

    ```
    wincode build: main moved while the build was starting: run <URL> builds commit 5d6e7f8, and the checks read 1a2b3c4
      why: the scheme, the configuration, the bundle ID and the other checks were made on the commit they read, not on the one the runner builds, so winCode downloads nothing from this run. The run goes on and uses macOS minutes until it ends.
      next: cancel it at <URL> if you do not want it, then run wincode build again to check and build the new commit.
    ```

### 13. Implementation plan, and acceptance

The work comes in five pull requests, each of one concern:
1. **Contract 2 of the reference workflow.** The template, its embedded copy, and actionlint in CI. `init --workflow` writes it byte for byte to a new file, and updates an existing one (section 8).
2. **The GitHub client** (`lib/src/github.dart`), and the start of `doctor --build`.
   - The client covers token sources, the API version, the one host, redirects without the token, rate limits and redaction.
   - The tests use a fake GitHub server on `127.0.0.1`.
   - `doctor --build` gets its settings, token, repository, workflow and contract checks.
3. **The project at the ref.**
   - `wincode_core`'s reader with a file source, the scheme and configuration rules, and the keys `build_name`, `target`, `flutter_version` and `min_xcode_version` in the loader.
   - The Flutter and Xcode checks, with `pub_semver`.
   - The build number: `auto` and `pubspec.yaml` as the two defaults, a given number, and the run list.
   - The rest of `doctor --build`.
4. **`build` itself:**
   - the plan, the question, the dispatch, the wait, the events, Ctrl-C, the timeout and `--run`;
   - the download, the zip reader's method that streams an entry to a file, the integrity and IPA checks, and the result;
   - `--dry-run` and the goldens.
5. **`--events` for `sign` and `upload`.**

**The Linux rehearsal, before any macOS minute** (2026-11-15, at the maintainer's request).
- **The setup:** a private test repository held a Linux copy of the contract 2 workflow. It had the same run name, hash file and `upload-artifact` step, and packed a 300 KB IPA-shaped zip instead of building an app.
- **What ran:** three dispatches through the REST API. Two started runs, each one job of about 6 seconds on `ubuntu-24.04`; the third was refused and started nothing.

The results:
- **The dispatch's answer:** 200, with `workflow_run_id`, `run_url` and `html_url`, and the header `X-GitHub-Api-Version-Selected: 2026-03-10`.
- **`display_title`** was `wincode <request_id>` for both runs. So was the run's `name`.
- **`digest`** is `sha256:` and the SHA-256 of the artifact's zip as downloaded, the same value as `upload-artifact`'s output `artifact-digest`. It is not the IPA's hash; the recorded hash covers the IPA.
- **The zip:** `wincode_core`'s `ZipArchive` opened the artifact, with `unsigned.ipa` and `unsigned.ipa.sha256` at its root, and the IPA inside it. The IPA's SHA-256 equalled the recorded hash. At 300 KB, the artifact leaves a full-size IPA to the first real run.
- **The redirect:** the download answered 302 with a signed link to another host (`*.blob.core.windows.net`), which downloaded with no token. The link's own parameters named an end 10 minutes after its start.
- **Which copy runs:** the branch's. Dispatched with `ref` set to a branch whose copy of the file differed from the default branch's, the run used the branch's copy. GitHub also checked the inputs against that copy:
  - an input declared only on the branch was accepted there;
  - at `main` it was refused with 422 `Unexpected inputs provided`, before any run.

**As built: part 5a.** The first pull request holds everything before the dispatch: `wincode_core`'s file source, the four keys, the GitHub client and its token, every check of sections 2, 3 and 8, `build --dry-run`, `doctor --build`, and `--events` for `build`, `sign` and `upload` (items 2, 3 and 5 above, and the parts of item 4 that need no dispatch).
- **Left for the next parts:** the dispatch and the wait (`--timeout`, `--yes`, `--run`), the artifact, and item 1, the contract 2 template with the update path of `init --workflow`. Until the template lands, the contract check passes only for a workflow written by hand, and message 1 names an update that `init --workflow` does not make yet.
- **Without `--dry-run`, `build`** makes every check and prints its plan. Then it ends with `not-implemented` (64), "dispatch not implemented yet (part 5b)", and starts nothing.
- **Ids that this ADR did not name,** given while building:
  - 78: `workflow-missing` (no `workflow:`), `workflow-input-missing` (the workflow requires an input that `build` does not send), `workflow-unreadable` (the file is not a workflow), `project-not-found` (no `pubspec.yaml` or `ios/Runner.xcodeproj` at the repository's root), `github-token-invalid` (a value that cannot be a token; it is not shown);
  - 64: `ref-is-commit`;
  - 69: `github-unavailable` (5xx after retries), `github-rate-limited` (a limit that clears in more than a minute; a shorter one is waited out, twice at most);
  - 1: `github-error` (an answer that GitHub does not document, a redirect included), `app-record-missing`.
- **Details that the checks settled:**
  - a failure that makes the next checks impossible ends the run with a line that says so, and a missing project is one failure and not a cascade of its files;
  - a public repository fails `build` and is a WARN for `doctor --build`, which has no `--allow-public`;
  - `doctor --build` adds its findings to those of the plain `doctor`, and `--dry-run` is a usage error for it;
  - a dry run sends no request and starts no program, so it does not ask `gh` for a token: the request names the variable the token would come from;
  - `GET /v1/apps/{id}/buildUploads` is in Apple's documentation (filters `cfBundleVersion`, `cfBundleShortVersionString`, `platform` and `state`, `limit` up to 200). `auto` reads it with `fields[buildUploads]=cfBundleVersion,state`, and an answer that Apple refuses with a client error other than 401 and 403 leaves `auto` on the builds alone, with a line that says so. Whether it lists uploads for a real account is for the first real run;
  - the events: `check` carries the check's name as `id`; `signing` has `status` `started` or `ended`, and `end` (`ok`, `failed`, `timedOut`, `tooBig`) on the second; `upload` has `stage` `created`, `parts` (with `sentBytes` and `totalBytes`) or `committed`; `processing` carries Apple's three states and the messages that are new, each with its `source`, `kind` and `message` as Apple sent it; `plan` of `upload` has `file`, `size`, `version` and `build`. The schema is `eventFields` in `lib/src/events.dart`, and the writer refuses a field that it does not list.

**As built: part 5b.** The second pull request holds the rest of `build`: the question, the dispatch, the wait, Ctrl-C, `--timeout`, `--yes`, `--run`, the artifact and its checks, and `--allow-public`'s deletion (the parts of item 4 that 5a left). It adds `ZipArchive.extractTo` to `wincode_core`, and to the GitHub client a write that is never repeated, a read with an `ETag`, a delete, and the download of an artifact through a redirect that carries no token.
- **Left for the next parts** (done in part 5c, and in "The first macOS run" below): item 1, the contract 2 template with the update path of `init --workflow`; the "other differences" warning of section 8, which compares with that template; and the real run on a macOS runner. Until the template landed, the contract check passed only for a workflow written by hand.
- **The same commit (section 4, step 3)** was a warning in the first draft of this ADR. It is a stop since the review of part 5b: `ref-moved` (1). The commit that the checks read is the one `build` records when it resolves the ref, and the run's `head_sha` is compared with it as soon as the run is known.
- **Ids that this ADR did not name,** given while building:
  - 1: `ref-moved`; `ipa-signed` (the IPA holds `embedded.mobileprovision`, and `build` refuses a signature it did not make); `output-unwritable` (the output folder cannot be made or written);
  - the ids of the checks of the IPA reuse those of `sign`: `ipa-unreadable` (not one app in `Payload/`, or an `Info.plist` that cannot be read) and `bundle-id-mismatch`;
  - from the dispatch's refusals (all with "Nothing was started."): 422 `Unexpected inputs` is `workflow-input-unknown` (78), `Required input` is `workflow-input-missing` (78), `No ref found` is `ref-not-found` (78), any other 422 or a 404 is `github-error` (1), a 403 is `github-forbidden` (77), a 401 is `github-unauthorized` (77), and a rate limit is `github-rate-limited` (69);
  - the warning `artifact-not-deleted`, for an artifact of a public repository that could not be deleted.
- **A dispatch that GitHub did not answer** is `offline` (69), and a 5xx is `github-unavailable` (69): in both the run may exist, so the message says that it does not know, gives the run's name to look for on the workflow's page, and names `--run`. The search by name after a 204 fails the same way. A rate limit or a 4xx is a refusal, and says that nothing was started.
- **The wait:**
  - It reads the attempt that the dispatch started (`.../runs/{id}/attempts/{n}` and its `/jobs`, with `run_attempt` taken from the run's first read), so that a re-run on GitHub is not followed. Each read sends the `ETag` of the last 200, and a 304 changes nothing.
  - The jobs are read once the run has left the queue.
  - A rate limit slows the polling and does not fail the build. A read that fails after its own retries is asked again; the third failure in a row ends the build with that failure (`offline`, `github-unavailable`, `github-unauthorized` …) and a next step that collects the run with `--run`, since the run goes on.
  - `--timeout` is 60 minutes by default, in minutes or in seconds with an `s`, as `upload` takes it; the wait stops before it would pass the limit.
- **Ctrl-C:**
  - winCode watches Ctrl-C, and SIGTERM where the system has it, from the moment before the dispatch is sent, so that a signal never ends the program while a run may have started.
  - It asks `Cancel the run on GitHub too?` only for Ctrl-C at a terminal without `--json`, `--events` or `CI`. Enter, any answer but `y` or `yes`, the end of the input and a second Ctrl-C are all a no.
  - The question and its answer are read asynchronously, so that a second Ctrl-C can answer it.
  - During the download of the artifact the run is over, so there is nothing to cancel: a signal stops the download, deletes the work folder and ends with `wait-stopped` (75) and `--run`.
  - A cancel that GitHub refuses ends with that refusal (`github-forbidden` …) and says that the run goes on.
- **`--run <id>`** needs the token, the repository (a public one needs `--allow-public`, as for a build) and the workflow, whose ID tells the run's workflow. It does not need the project, `flutter_version` or `min_xcode_version` in `wincode.yaml`. `--ref`, `--build-name`, `--build-number` and `--dry-run` are usage errors with it. `--timeout` counts from the start of the wait. It asks no question, since it starts nothing.
- **The question** is asked after the findings and the plan. `confirmation-required` (64) comes before any request, as `upload`'s does: without `--yes`, and without a terminal, or with `--json`, `--events` or `CI`.
- **The artifact:**
  - the checks run in this order: the zip against GitHub's `digest`, the files in the zip, the IPA against the hash that the build job recorded, and the IPA itself. The digest covers the zip and the recorded hash covers a file inside it, so the digest has to be checked first;
  - `unsigned.ipa.sha256` must start with 64 hexadecimal digits and be under 1,024 bytes;
  - the IPA replaces `<output>/unsigned.ipa` by a rename inside the output folder, after every check; a check that fails leaves the old file alone, and the work folder `.wincode-build-<random>` is deleted whatever happens;
  - the artifact of a public repository is deleted after the IPA is in place and not before: a delete cannot be undone, and a move that failed would have lost the IPA. When a check fails there, `next` adds that the artifact is still public and where to delete it.
- **The events:**
  - `job` has `job`, `status` and `conclusion`; `step` has `job`, `number`, `name`, `status` and `conclusion`. A job or a step that has not started (`queued`) is not an event;
  - `wait` carries `minutes`, the time the jobs have used so far, rounded up per job and at least one for a job that started;
  - the findings of the artifact stage are `check` events too, and `artifact` is written when the download is done, before it is checked;
  - the text for people (one line each time the run, a job or a step changes) goes to stderr in every mode, and the question to the stream of the report, which is stdout without `--json` or `--events`.
- **`minutes` in the result** is the same estimate, for the jobs read last. It is null when the run never reached a job.
- **The program ends with `exit`** after it flushes its output (`bin/wincode.dart`): an interrupted build leaves a timer and a read of standard input behind, and they would keep the process alive for up to 30 seconds.

**The real check of part 5b** (2026-11-15, with the maintainer's yes, on the Linux workflow of the private test repository; no macOS).
- **The setup:** a new branch of the test repository (its `main` and its first rehearsal branch were not touched) with a made-up Flutter project (the sample of `wincode_core`'s tests, bundle ID `org.example.demo`, one shared scheme) and a Linux copy of the contract 2 workflow. The copy declares the seven inputs that `build` sends, carries the request ID in its run name, and packs a 300 KB IPA-shaped zip whose XML `Info.plist` holds the version and build number it was given, with the same hash file and `upload-artifact` step as the reference workflow. The token was `gh`'s login, which `doctor --build` reports as broad.
- **`doctor --build`** passed every check of `build` against that branch, with real reads (12 requests). One request timed out after 20 seconds and its retry answered, as designed.
- **The first dispatch found a fault.** `build` stopped after the dispatch with `run-not-found`: GitHub showed the run as `wincode-ios`, the name of the workflow, and the request ID's name only a moment later (section 4, step 2). The run itself succeeded. The fix waits for the name, and a fake run that shows the workflow's name for two reads tests it.
- **`--run` on that run** collected it end to end with GET requests: the 302 to GitHub's storage on another host (the log shows its host only), the zip against `digest`, the two files, the IPA against the recorded hash, and the IPA's bundle ID, version and build number, from the run's name. Exit 0.
- **A second build** (`--build-number 2`: the first run, which succeeded, holds number 1, and `build` refused to reuse it before any request, which also showed the run list's rule on real runs) ran the whole way in 66 seconds, with 22 requests, one of them the dispatch:
  - the dispatch answered 200 with `workflow_run_id` and `html_url`, and GitHub showed the run under its own name on the second read, 5 seconds later;
  - the run's `head_sha` was the commit that the checks had read, so the same-commit check passed;
  - the first read of the run found it `in_progress`, and the second, 30 seconds later and with the `ETag` of the first, found it `completed`; the events held the `run`, `job` and `step` changes of both reads;
  - the artifact (301,112 bytes) was downloaded through the redirect with no token, every check passed, and `unsigned.ipa` (300,975 bytes) was in the output folder, with no work folder left; exit 0, with the one warning of a flat file without credentials;
  - the result's `minutes` was 1, for a job of 8 seconds on `ubuntu-24.04`;
  - no token, no `Authorization` header and no part of the signed link was in the events, the text for people or the verbose log.
- **What it did not show:** a branch that moves (`ref-moved` is tested against the fake only: the real run built the commit that was checked), Ctrl-C, the timeout, a failed or cancelled run, a rate limit, `--allow-public` (the repository is private), a full-size IPA, and macOS.

**As built: part 5c.** The third pull request holds item 1: the contract 2 template, the update path of `init --workflow`, the warning for a workflow that differs from the template (section 8), the INFO line of `doctor --build` (section 10), and actionlint in CI. No dispatch was sent and no runner was used to build or check it.
- **The template** (`packages/wincode_cli/templates/wincode-ios.yml`, embedded by `tool/embed_template.dart`) is the text of section 8, with these settled:
  - **Two actions, each pinned to a commit with its release in a comment:** `actions/checkout` v7.0.1 is `3d3c42e5aac5ba805825da76410c181273ba90b1` and `actions/upload-artifact` v7.0.2 is `cf430e030ddbb5b0abf93d22962f4752f3646cd9`. Both were checked on 2026-11-16: each is the latest release (`GET /repos/<owner>/<repo>/releases/latest`), and its tag (`GET .../git/ref/tags/<tag>`) is a lightweight tag whose object is that commit, so there was no annotated tag to dereference. The pins are refreshed by hand, with the same two reads; nothing refreshes them.
  - **The runner label and the Xcode path cannot be pinned,** since they name images that GitHub changes. They were checked against GitHub's runner-images repository on 2026-11-16: its `README.md` lists `macos-26` as a label of "macOS 26 Arm64", and `images/macos/macos-26-arm64-Readme.md` (image version 20261102.0473.1) lists Xcode 26.6, the default, at `/Applications/Xcode_26.6.app`. The template says the owner of the repository sets `XCODE_APP`, `runs-on` and `timeout-minutes`.
  - **The Flutter step is plain shell:** a shallow clone of the tag (`git clone -q --depth 1 --branch "$FLUTTER_VERSION"`), with no third-party action, so that no code that is not GitHub's runs on the runner. The cost is no cache, about a minute.
  - **The oldest-Xcode check is a plain POSIX `awk` program** that compares the two versions number by number (`split` on dots, then `+ 0`), so that GNU and BSD `awk` agree; it uses none of the extensions of gawk, and no `sort -V`. A missing component counts as 0 (`26` is `26.0`), and an Xcode that prints no version is older than any minimum. A test runs the step's own text under `sh`, with stubs for `sudo` and `xcodebuild`, for fifteen pairs of versions, under every `awk` that the machine has. On Ubuntu 24.04 those are GNU awk 5.2.1, mawk 1.3.4, original-awk (the one-true-awk, version 20231127, from which macOS's awk descends), and BusyBox 1.36.1's. All agreed. **macOS's own `awk` was not tested, and cannot be here:** the first real run on a macOS runner is its test. That run passed the step for one case, 26.6 against 26.0 ("The first macOS run" below); other pairs of versions, and other versions of macOS's `awk`, are untested.
  - **The step summary and the hash file** are written by the packing step, after `shasum -a 256`, as section 6 says. The artifact `unsigned-ipa` keeps its two files for one day and fails when one is missing. No `${{ ... }}` is inside a `run:` block, no secret or token is read, and `persist-credentials` is false: tests read all three from the template.
  - **actionlint** passes on the template (version 1.7.12, run with shellcheck 0.9.0 on Linux), and CI runs it (below).
- **`init --workflow`** routes by what exists, without `--app`:

  | State | What happens |
  | --- | --- |
  | The workflow exists | The update: the template with the old file's `XCODE_APP`, `runs-on` and `timeout-minutes` (each checked: `XCODE_APP` is `/Applications/<name>.app`, `runs-on` one label, `timeout-minutes` 1 to 999; a value that fails is not kept, and a note says which and what the new file has), the diff, the question, the `.bak`, the write |
  | No workflow, and a `wincode.yaml` (without `--force`) | The template is written to a new file, with no question, since nothing is replaced. `wincode.yaml` is not touched. This used to be `config-exists`; `--force` keeps its old meaning there (replace `wincode.yaml`, and copy the workflow) |
  | Neither | The full `init`, as before, plus the copy |
  | `--app`, and the workflow exists | `workflow-exists` (1), whose next step is to run `wincode init --workflow` alone |

  - **The options that describe `wincode.yaml`** (`--bundle-id`, `--team-id`, `--profile`, `--profile-dir`, `--entitlements`, `--workflow-ref`, `--output`, `--flavor`, `--configuration`, `--credentials`) are `init-value-invalid` (64) in the first two rows.
  - **The question** is `[y/N]`, default no, and only `y` or `yes` writes. Without a terminal, in CI, with `--json`, and without `--yes`, it is `init-input-missing` (64) after the diff and before any write. `--force` is not a yes. `--dry-run` shows the diff and writes nothing.
  - **The order of writes** is `wincode.yaml` (through the loader's own reload and rollback), then the `.bak`, then the workflow. If the workflow or the `.bak` cannot be written, all three files are put back as they were, and the failure is `workflow-unwritable` (1).
  - **`wincode.yaml`** gets `flutter_version` only when the old workflow had a valid `FLUTTER_VERSION` and no `flutter_version` is set: at the top level of a flat file, under `defaults:` (made if absent) of a file of apps, by `yaml_edit`, so comments and order stay. When one is set anywhere (`defaults` or an app), it wins, and a note names the old workflow's release when it differs. Without a `wincode.yaml`, a note says to set `flutter_version: <release>` by hand. A non-empty `FLAVOR` of the old workflow is named in a note and moves nowhere, and `min_xcode_version` is never inferred: `XCODE_APP` is the Xcode the job selects, not the oldest that may build the app. After a workflow is written, one line names the keys that `wincode.yaml` still lacks for a build.
  - **Line ends:** the old file may have a byte order mark and CRLF. The new file is LF, the `.bak` keeps the old bytes, and a file that differs from the new one only by CRLF is "up to date".
  - **`--json`** has `workflow` as `copied`, `would-copy`, `updated`, `would-update` or `up-to-date`, `backup` (the name) when one was written, and `flutter_version` under `config` when it was added.
  - `init` runs no `git` command and writes no file but `wincode-ios.yml`, its `.bak` and `wincode.yaml`: a test starts it with a process hook that fails when called, and compares the whole folder before and after.
- **The warning** `workflow-differs` (a WARN of the check `workflow-contract`) is given by `build` and `doctor --build` when the workflow has contract 2 and is readable. It never stops a build.
  - The two files are compared as parsed YAML, key by key. `runs-on`, `timeout-minutes`, `XCODE_APP` (at the top or in a job) and the `description` of an input are removed first, and an empty `env` with them. A pin is not.
  - The parts are named: `input <name>`; `step "<name>"`, or the action's name when the step has none (`step "actions/checkout"`), with `(added)` or `(missing)` for a step that only one file has; `job <id> <key>` for another key of a job and `job <id>` for a job that only one file has; `on` for anything else under `on:`; `the order of the steps`; and any other top-level key by its name, such as `permissions`.
  - `why` says that a changed workflow belongs to its owner, that the contract and the IPA's checks still hold, and that the three values are not counted; `next` is `wincode init --workflow`. With `--verbose`, the differing lines come out of the checker's log, as `init` shows them (`-` the workflow's, `+` the template's, with the workflow's three values put into the template first).
- **`doctor --build`** gives one INFO line (check `actions-write`) after the token's, with the text of section 10. Plain `build` does not.
- **CI** has a job `actionlint` (`.github/workflows/dart.yml`) that downloads actionlint 1.7.12 for Linux, checks its SHA-256 (`8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8`, from the release's checksums file and from the downloaded file), and lints the template. It lints the template only: with shellcheck, which the runner has, the repository's other workflows have findings that are older than this part.
- **Ids that this ADR did not name,** given while building: `workflow-differs` (a WARN) and `workflow-unwritable` (1). Every other id is one that parts 5a and 5b already had: `workflow-unreadable` and `workflow-contract` (78), `init-input-missing` and `init-value-invalid` (64), `backup-exists`, `workflow-exists` and `init-edit-failed` (1), and `init-wrote-invalid` (70).
- **Tests:** `fake_github` now serves the real template as the repository's workflow, so every test of `build` also shows that the template passes the contract, inputs and Xcode checks. One test that removed an input of the old, shorter fixture by its text now removes it from the template's text (with its `description` line).
- **A report, not a fix: "The handle is invalid" on Windows.** The real check of part 5b saw that error once around standard input, and its text was not kept. Eight probes since then (an open pipe, a closed pipe, `NUL`, a tool's null stdin, a detached child, a detached child with stdio, standard input closed in the shell, and, from a process with no console and no standard handles, started from `wscript`) never raised it. In that last process `stdin.hasTerminal` is true and an asynchronous read never returns, which `build` meets only after a Ctrl-C asks its question, where a second Ctrl-C answers. It is not reproduced, so no code changed; GitHub issue 31 holds what was seen.

**The real check of part 5c** (2026-11-16, Linux workflow only; no dispatch, no run, no macOS; `doctor --build` sends GET requests only, 12 each).
- **The setup:** a new branch `rehearsal-5c` of the private test repository, from the branch of part 5b, whose one changed file is the workflow: winCode's template, written by `init --workflow` into a copy of the project, then changed in that copy only in the two values `runs-on` (`ubuntu-24.04`) and `timeout-minutes` (5), with a first line that says it is a fixture and is never to be copied. Its steps need macOS, and it is never to be dispatched. The branch's `main`, the first rehearsal branch and the one of part 5b were not touched. The workflow only runs on a dispatch, and afterwards the repository had no run for the branch.
- **`init --workflow`** on the hand-written Linux workflow of part 5b (contract 2) showed the diff, kept `ubuntu-24.04` and 5 (and its Xcode, which equals the template's), wrote the `.bak` byte for byte, and left `wincode.yaml` as it was (it already set `flutter_version`). A second run said "up to date". With the file deleted, `init --workflow` wrote the template, and the file was the template byte for byte (5,584 bytes, equal hashes).
- **`doctor --build` on `rehearsal-5c`:** PASS for the contract, for the seven inputs, for Xcode 26.6 against 26.0, for the Flutter constraint and tag 3.47.7, the scheme, the configuration and the bundle ID; no WARN for the workflow; the new INFO line. It also FAILed two checks that are not about the workflow: the key folder of the plain `doctor` (not set here), and `build-number-not-higher`, because the two successful runs of part 5b, less than a day old, hold the numbers 1 and 2 (the rule of section 3, on real runs, again).
- **`doctor --build` on `rehearsal-5b`** (the hand-written workflow): the contract PASS, and one WARN, `workflow-differs`, naming six parts: `step "actions/checkout"`, `step "Xcode"`, `step "Flutter"`, `step "Build the archive, unsigned"` and `step "Package the app as an unsigned IPA"` (each `(missing)`) and `step "Pack a small IPA-shaped file"` (`(added)`). The same two other FAILs.
- **What it did not show:** a run of the template, on Linux or on macOS (it needs the maintainer's word), the `awk` of macOS, a `wincode.yaml` that `init` changed on real data (the rehearsal project already set `flutter_version`; the tests cover it), and the first real build with `actions/checkout` and `actions/upload-artifact` as pinned.

**The first macOS run** (after part 5c; a made-up test app, in a private test repository).
- **The setup:** a GitHub-hosted `macos-26` runner with Xcode 26.6 and Flutter 3.47.3. The app is a minimal Flutter app with two common plugins and CocoaPods turned on in its `pubspec.yaml`.
- **`wincode build`** dispatched once, followed the run and downloaded the artifact. Every check of the IPA passed: the zip against GitHub's `digest`, the files in the zip, the hash that the build job recorded, and the IPA's bundle ID, version and build number, with no profile. The job took about 2 minutes, and 3 macOS minutes were billed. The log shows that `pod install` ran.
- **The Xcode step:** the `awk` comparison of the selected Xcode with `min_xcode_version` ran on the macOS runner and passed for one case, 26.6 against 26.0.
- **Sign and upload:** `wincode sign` signed that unsigned IPA (zsign in WSL2 on Windows), and `sign --verify-only` and `upload --dry-run` passed. The maintainer ran `wincode upload`, and App Store Connect processed the build as `VALID` (test app, build number 16). So the chain build, sign, upload was exercised end to end on a real macOS runner.
- **Token permissions** (the messages and fixes are in "Troubleshooting the GitHub token" in `packages/wincode_cli/README.md`):
  - a fine-grained token whose resource owner is not the organization cannot see the organization's private repository: GitHub answers 404, which `build` reports as `repository-not-found`;
  - the repository must be selected in the token's repository access, or the answer is the same 404;
  - without Actions: read and write, the dispatch is refused with 403 (`github-forbidden`, "Resource not accessible by personal access token") and nothing starts. `doctor --build` passes with such a token, as section 10 says it can: it cannot test write permission ahead, and says so in an INFO line.
- **Redaction:** with `--redact`, the variable name `WINCODE_GH_TOKEN_<APP>` is printed with the app's redacted name (`..._APP_1`).
- **What it did not show:** a branch that moves (`ref-moved`), Ctrl-C, the timeout (75), a failed run, `--allow-public` and its cleanup, a full-size IPA (the test IPA is about 6 MB), a public repository, a flavor, and other versions of macOS's `awk` than the single case above. This record does not say whether `GET /v1/apps/{id}/buildUploads` lists uploads, or whether the app was one app of a file of apps.

**Accepted when** these all hold. They replace ADR-0013's phase 5 criteria and ADR-0014's additions to them.
- **Against a fake GitHub server** (no network in CI):
  - the dispatch carries every input, and the run is found from the dispatch's answer, and by its name after a 204;
  - the dispatch is sent once, whatever happens to its answer: a lost answer, a 5xx and a refusal each leave one request;
  - a run that builds another commit than the one that was checked is reported with `ref-moved`, and nothing is downloaded or cancelled;
  - the wait gives job and step events;
  - a failed run names its step; a cancelled run, and a run that never started, each give their own message;
  - the timeout exits 75;
  - Ctrl-C at a fake terminal: answered no, the run goes on (75); answered yes, the cancel request is sent;
  - `--run` collects a run;
  - the artifact is downloaded through a redirect that does not carry the token, and each integrity failure is reported;
  - a public repository is refused, and with `--allow-public` the artifact is deleted.
- **No paid run on a failed check.** Each check before the dispatch fails with no dispatch request: the fake server fails the test if it gets one. The checks are the contract, the scheme, the configuration fallback, the bundle ID, the target, a `pubspec.yaml` that does not allow the Flutter release, a Flutter tag that `flutter/flutter` does not have, an Xcode older than the minimum, the build number not higher, a build in progress, a public repository and a missing confirmation.
- **Two apps of one workflow** start two runs, each with its own inputs and app tag.
- **The default build number** is `auto` in a file of apps and `pubspec.yaml`'s number in a flat file.
- **The token:** `WINCODE_GH_TOKEN_<APP>` wins over `GH_TOKEN` for its own app only, and its name is redacted.
- **`--dry-run` sends no request:** a server that fails on any request proves it.
- **`--events`,** for `build`, `sign` and `upload`: golden lines, each line valid JSON, and the last line equal to `--json`'s object. `upload --events` without `--yes` is `confirmation-required`.
- **No secret in any output,** `--verbose` included: no token, no signed link, no `Authorization` header.
- **The template:** it passes actionlint, and `init --workflow` writes it byte for byte to a new file.
- **The update of a workflow** by `init --workflow` shows the diff with the old file's values kept, asks, and writes the `.bak`. It stops on an existing `.bak` unless `--force`, writes nothing with `--dry-run`, and changes `wincode.yaml` only by adding `flutter_version`, when that has none.
- **The real run:** `wincode build`, `wincode sign` and `wincode upload` of one app of a file of apps, in a row, end with a build processed as valid. It uses macOS minutes and an upload, with the maintainer's yes. It also confirms whether `GET /v1/apps/{id}/buildUploads` lists uploads. *Met for the build, sign and upload of a test app by "The first macOS run" above; what that record leaves open is named there.*

### 14. Out of scope, and the review's decisions

Out of scope:
- `ship` and `--then`, for now (section 1);
- `--all` for `build`;
- GitHub Enterprise Server (section 5);
- a Flutter project that is not at the repository's root.

The first draft asked the maintainer eleven questions. The answers are decisions now, applied in the sections named:
1. **Variants:** no shared bundle ID. Each variant is an app with its own bundle ID, and ADR-0014's refusal of a repeated bundle ID stays (section 2).
2. **Public repositories:** refused without `--allow-public`. With it, winCode deletes only the artifact, and nothing is encrypted (section 6).
3. **`auto`:** the default in a file of apps, with the 24-hour window for runs (section 3).
4. **Tokens:** one `GH_TOKEN`, with an optional variable per app, `WINCODE_GH_TOKEN_<APP>`, named as a credentials reference's variables are (section 5).
5. **`--events`:** for `sign` and `upload` too (section 9).
6. **GitHub Enterprise Server:** not supported (section 5).
7. **Updating the workflow:** `init --workflow`, only when the user runs it, shows the diff and writes with a `.bak` (section 8).
8. **The wait:** 60 minutes by default for `--timeout`, and winCode never cancels a run on its own (section 4).
9. **Cost:** in minutes only (section 7).
10. **`ship`:** not for now (section 1).
11. **The question before a build:** y/N; `upload` keeps the typed app name (section 7).

The review also added the Flutter and Xcode versions from the project (section 2) and the `auto` default (section 3). No question is left open.

## Consequences

- **No command needs `gh` any more.** It is one of three places a token can come from. A Linux server needs `wincode` and `GH_TOKEN`; a desktop user logged in to `gh` needs nothing new.
- **winCode holds a GitHub token,** in memory, during `build` and `doctor --build`. ADR-0013's "winCode holds no GitHub token at all" (section 7) gives way to the rules of section 5.
- **Each repository updates its workflow to contract 2** before `build` works there. `init --workflow` does it, keeping the old file's `XCODE_APP`, `runs-on` and `timeout-minutes`; the Flutter release moves from the workflow's `env` to `flutter_version` in `wincode.yaml`. No `build` had run when this was written, so no existing run breaks.
- **ADR-0014's phase 5 changes:**
  - `build_number` is always sent, and the workflow requires it; in a file of apps it is `auto` unless given;
  - `build_name`, `target`, `flutter_version` and `min_xcode_version` are new inputs, reserved in `workflow_inputs`, which holds at most 18 entries;
  - `configuration` is read by `build` too;
  - two things that ADR-0014 (section 8) left out of scope are now keys: the version per app (`build_name`), and the Flutter and Xcode versions per app (`flutter_version`, `min_xcode_version`).
- **A project adds two keys before its first build:** `flutter_version` and `min_xcode_version`, once in `defaults` or per app.
- **`build` reads App Store Connect** when the app has credentials, with GET requests only, to check the build number. In a flat file without credentials it still runs, except with `auto`.
- **`init --workflow` can replace a workflow,** after a diff and a question, and keeps a `.bak`. ADR-0013's "it never replaces that file" no longer holds.
- **`sign` and `upload` gain `--events`.**
- **A public repository needs `--allow-public`,** where ADR-0013's reference workflow only warned.
- **The run list on GitHub shows** a hash of each app's bundle ID, its version and its build number. None of them is secret, and no app's name appears.
- **Cost stays visible:** a question before every paid run at a terminal, `--yes` in automation, and the minutes per job in the result.
- **To revisit:**
  - flutter_tools' scheme and configuration rules, each time a project moves to a new Flutter;
  - what the first real run did not show, such as a full-size IPA (section 13, "The first macOS run").

## Alternatives considered

- **`gh`, a GitHub App, or OAuth's device flow:** section 5.
- **Finding the run only by its name:** this was ADR-0013's plan, and it is still the fallback for an answer without a run ID. The dispatch's answer names the run, without a race against other runs of the same workflow.
- **`repository_dispatch`:** it needs Contents write on the repository, it runs only from the default branch, and it returns no run.
- **Webhooks:** they need a server that GitHub can reach. Polling is enough for one run.
- **`concurrency:` in the workflow, against two builds of one app:** when a new run joins a group, GitHub cancels the run already waiting in it, so a paid run can be lost. It does nothing for the build number either. The run list refuses before anything starts.
- **A counter file for build numbers,** in the repository or on disk: that means a commit for every build, or a file to keep in step between machines.
- **Reserving the number at Apple** by creating the build upload before the build: a write to Apple before anything is built, and a record left behind when the build fails.
- **`--dart-define` for the version, the number or the entry point:** some projects refuse it, and Flutter has options of its own for all three.
- **The Flutter and Xcode versions only in the workflow file,** as in contract 1: one workflow cannot vary them per app, and nothing compares them with the project.
- **The Flutter version from the project's own files,** such as an FVM configuration or `pubspec.yaml`'s `environment: flutter:`. Not every project has an FVM file, and a constraint is a range, not one release; winCode checks the constraint against the key instead (section 2).
- **The runner's default Xcode:** winCode could not check it before the dispatch.
- **Encrypting the IPA, or deleting the whole run, in a public repository:** rejected in review (section 6).
- **Checking the local checkout instead of the ref:** section 2.
- **An online `--dry-run`:** it would break ADR-0013's promise that `--dry-run` sends nothing, on which scripts rely. `doctor --build` is the online preview.
- **NDJSON under `--json`:** `--json` means one object for every command, and callers rely on that.
- **The recorded hash alone, or `digest` alone:** each covers only one path (section 6).
- **The hash read from the job's log:** that is another path for the hash, but the log is the build's whole output, in a form that winCode does not control.
- **An unzipped artifact (`archive: false` in `upload-artifact`):** GitHub documents the download as a zip only.
- **GitHub's billing API, for real costs:** it needs billing permissions on the account, far beyond what a build needs.

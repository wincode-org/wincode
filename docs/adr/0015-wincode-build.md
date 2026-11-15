# 0015. wincode build: the unsigned IPA from a GitHub macOS runner

- Status: Proposed
- Date: 2026-11-15
- Amends: ADR-0013 (sections 1, 3, 6, 7, 8 and 11, phase 5 in section 10, and the alternative "The REST API instead of `gh`") and ADR-0014 (sections 1, 6 and 8). Design only: nothing here is implemented, and no workflow was run for it.

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
| `--build-number <n>` or `--build-number auto` | The build number (section 3). Without it, the build number comes from `pubspec.yaml` at the ref |
| `--timeout <minutes>` | How long to wait for the run, counted from the dispatch: 60 minutes by default, or a number of seconds ending in `s`, as `upload` takes it. It ends the wait, never the run (section 4) |
| `--yes` | Start the run without the question of section 7. Needed with `--json` or `--events`, in CI, and without a terminal |
| `--allow-public` | Build in a public repository (section 6) |
| `--events` | Write progress as JSON lines on stdout (section 9) |
| `--run <id>` | Start nothing: wait for run `<id>`, which an earlier `build` started, then download and check its IPA (section 4). `--ref`, `--build-name` and `--build-number` are refused with it (64), since the run already has them |

**Chaining: there is no `build --then sign,upload` and no `ship` command.**

| Option | For | Against |
| --- | --- | --- |
| A. `build --then sign,upload` | One command line | `upload` asks for the app's name separately because Apple never gives back a used build number. With `--then`, either `build`'s `--yes` would have to stand for that answer, or `upload` would ask in the middle of an unattended run. One exit code and one object for three steps hide which step failed, and the options of three commands share one line |
| B. `wincode ship` now | It is ADR-0008's name for the lane | The same problems, plus a design of its own: a plan of the three steps before anything starts, one confirmation up front, a record so that a second run resumes after the failed step instead of building again, events across the steps, and a mapping of exit codes. ADR-0013 (section 9) waits until each step works, and `build` does not exist yet |
| **C. Neither: the caller chains the steps** (chosen) | Each step keeps its exit code, its object and its confirmation. A calling tool already runs one step at a time (ADR-0014, section 7) | Three commands to type, or one shell line |

**C is chosen.** The steps hand over through the app's output folder: `build` writes `unsigned.ipa`, which `sign` reads by default, and `sign` writes `signed.ipa`, which `upload` reads.

```sh
wincode build --app alpha --yes && wincode sign --app alpha && wincode upload --app alpha
```

### 2. What an app builds: inputs in `wincode.yaml`, checked at the ref

**Two new keys** are allowed in a flat file, in an app's entry and in `defaults`:

| Key | What it is, and what the loader checks |
| --- | --- |
| `build_name` | The version (`CFBundleShortVersionString`). `build` gives it to Flutter as `--build-name`, instead of the part of `pubspec.yaml`'s `version` before `+`, so that the App Store version can run ahead of the Android one. It is one to three whole numbers joined by dots, the shape that Apple takes and that `preflight` already reads (`^\d+(\.\d+){0,2}$`) |
| `target` | The Dart entry point, which `build` gives to Flutter as `--target`. It is a path in the project under `lib/`, ending in `.dart`, of at most 64 characters: letters, digits, `.`, `_`, `-` and `/`, with no `..` part. The default is Flutter's own, `lib/main.dart` |

- **The version comes from,** in this order: `--build-name`; the app's `build_name`; `build_name` in `defaults`; `pubspec.yaml`'s `version` at the ref. If none of them gives one, the build stops with `build-name-missing` (78).
- **`flavor`** stays as ADR-0014 defines it, but the workflow now takes it as an input (section 8) instead of a value under `env`.
- **`configuration`** is now also read by `build`, for the check below. ADR-0014 said "Read by `init` only". It is not sent to the workflow: `flutter build ipa` has no option for the Xcode configuration, and derives it from the flavor.
- **There is no key for the build number,** since it changes with every build (section 3).
- **No `--dart-define`, and no free-form arguments.** Each input has a fixed meaning, and `flutter build ipa` takes it as an option of its own: `--flavor`, `--target`, `--build-name`, `--build-number`. A project that keeps each flavor's values in its own files needs nothing more.

  A workflow that a user has changed can still take more values through `workflow_inputs` (ADR-0014), which the reference workflow does not read. `build_name` and `target` join the input names reserved there. `workflow_inputs` holds at most 20 entries, so that a dispatch stays within GitHub's limit of 25 inputs.
- **A DEV variant and a store variant of one app are two apps,** each with its own bundle ID. App Store Connect sees them the same way: each has its own app record and its own build numbers.

  ```yaml
  defaults:
    team_id: TEAM000001
    credentials: team-one
    workflow: example-org/example-app/.github/workflows/wincode-ios.yml@main
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

  Variants that share one bundle ID cannot be two apps of one file, because ADR-0014 refuses a repeated bundle ID. An example is a DEV flavor shipped to testers under the store app's record. Open question 1 asks what to do about them.

**`build` checks the project at the ref's commit before the dispatch,** through GitHub's API. It checks that commit because that is what the runner builds. The local checkout may be on another branch, may hold changes that were never pushed, or may not exist at all on a server.

| What | The rule | When it does not hold |
| --- | --- | --- |
| Version and number | `pubspec.yaml` at the commit gives them when nothing else does | `build-name-missing`, `build-number-missing` (78) |
| Target | The file exists at the commit | `target-missing` (78) |
| Scheme | flutter_tools 3.47 builds the scheme named after the flavor with its first letter in capitals (`store` gives `Store`), or `Runner` when there is no flavor. If no scheme has exactly that name, it takes the one scheme that matches it ignoring case. The scheme must be a shared scheme of `ios/Runner.xcodeproj` (`xcshareddata/xcschemes/`). A scheme kept only in someone's `xcuserdata` is not in the repository, so the runner does not have it | `scheme-missing` (78) |
| Configuration | flutter_tools 3.47 builds `Release-<Scheme>`, matched ignoring case. Failing that, it builds the one configuration whose name holds both `Release` and the scheme. If none does, it builds `Release`; if several do, it stops. The configuration it would build must be the app's `configuration`, ignoring case; the default is `Release-<flavor>` | `configuration-mismatch` (78). The message says so when Flutter would fall back to `Release` |
| Bundle ID | The configuration's `PRODUCT_BUNDLE_IDENTIFIER` must be `bundle_id`. It is read with `wincode_core`'s reader, as `init` reads it | `bundle-id-mismatch` (1, ADR-0013's id). A WARN when it cannot be resolved, for example from an xcconfig file that is not committed |

- **A check fails only on a definite finding.** When winCode cannot read something, it gives a WARN, and the IPA's checks after the run (section 6) still apply. Two examples: a listing that GitHub truncates, and a file over GitHub's size limit.
- **Requests,** one each:
  - the commit (`GET .../commits/{ref}`);
  - its whole tree in one listing (`GET .../git/trees/{sha}?recursive=1`), which shows the shared schemes and whether the target exists;
  - `project.pbxproj`, each xcconfig file under `ios/`, `pubspec.yaml`, and the workflow file (section 8), read raw through the Contents API at that commit.
- **`wincode_core`'s build-settings reader gets a parameter** that reads a file by its path, from the local disk by default. `init` and `build` then resolve settings with the same reader.
- **The rules are those of flutter_tools 3.47,** the release that the reference workflow pins. If a later Flutter changes them, the IPA's bundle ID check after the run still catches a wrong build, and the rules are updated with the template.
- **The Flutter project is at the repository's root,** where the reference workflow builds it.

### 3. The build number

| Option | For | Against |
| --- | --- | --- |
| A. Always given on the command line | Nothing is hidden | Every caller has to look up the highest number first |
| B. Always `auto` | No bookkeeping | It needs the App Store Connect key in a step that otherwise needs none, and it cannot work with build numbers that contain dots |
| **C. `pubspec.yaml`'s number by default, or `--build-number <n>`, or `--build-number auto`** (chosen) | A one-app project works as it does by hand, and `auto` is there for a file of apps. In every case the number is decided before the dispatch | Three sources to explain |

**C is chosen.** Whatever its source, the number is decided before the dispatch and sent as the `build_number` input, and the plan says where it came from. When there is no source, the build stops with `build-number-missing` (78): no option was given, and `pubspec.yaml`'s `version` has no `+N`.

**`auto` gives the highest number known for the app, plus one.** It looks in two places:
- **App Store Connect:** the app's builds, read with `preflight`'s GET requests and the app's credentials (ADR-0014, section 2). It also reads the app's build uploads, if `GET /v1/apps/{id}/buildUploads` exists; the implementation checks that first. An upload that Apple has not yet turned into a build holds its number too.
- **The app's recent runs** (below).

The highest number must be a whole number. A highest number with dots, such as `57.1`, fails `auto` with `build-number-auto` (1): winCode does not guess the next step of someone else's numbering scheme. An app with no credentials fails `auto` with `credentials-missing` (78).

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
2. **Check that the run is ours.** `GET .../actions/runs/{id}`, read again for up to 2 minutes until GitHub shows the run. Its `display_title` must be `wincode <request_id>`, and its `event` must be `workflow_dispatch`; otherwise, `run-not-found` (1).

   An answer without a run ID (204, as the previous API version answers) falls back to ADR-0013's search: list the workflow's dispatched runs every 5 seconds, for up to 2 minutes, until one has that name.
3. **Its commit.** The run's `head_sha` should be the commit that section 2 checked. If the branch moved in between, a WARN names the commit that the run builds, and the IPA's checks still apply.
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

**winCode looks for the token in this order,** the order in which `gh` itself reads the variables:
1. `GH_TOKEN`;
2. `GITHUB_TOKEN`;
3. `gh auth token --hostname github.com`, when `gh` is installed and logged in. A desktop user of `gh` needs nothing more.

When none gives a token, the build stops with `github-token-missing` (77). On a Linux server without `gh`, set `GH_TOKEN` in the service's environment, from the server's secret store.

**The least that the token needs** is a fine-grained personal access token limited to the app's repositories, with:
- **Actions: read and write,** to start a run, read runs, jobs and artifacts, cancel a run and delete an artifact;
- **Contents: read,** for the project and the workflow at the ref;
- **Metadata: read,** for the repository itself (`GET /repos/{owner}/{repo}`).

A classic token, and the token of `gh`'s login, need the `repo` scope, which can do much more. `doctor --build` says which kind of token it found.

**How winCode treats the token:**
- **It is never in `wincode.yaml`.** There is no key for it, and the loader already refuses keys that look like secrets, `token` among them.
- **It is never printed,** `--verbose` included: it is registered with the redactor as a secret as soon as it is read. Output names only its source and its kind (`GH_TOKEN, a fine-grained token`), which winCode tells apart by GitHub's prefixes (`github_pat_`, `ghp_`, `gho_`).
- **It is sent only to `https://api.github.com`.** Redirects are followed by hand, without the token. The artifact's download answers 302 with a signed link to GitHub's storage, valid for one minute. That link is registered with the redactor too, and `--verbose` shows only its host.
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
3. **Transfer.** When the artifact's `digest` has the form `sha256:<hex>`, the zip's SHA-256 must equal it (`artifact-integrity`, 1).
   - GitHub's reference does not say what `digest` covers; `upload-artifact` calls its output `artifact-digest` the "SHA-256 digest of an Artifact".
   - The first real run confirms that it is the zip's. Until then, any other form gives an INFO line, not a check.
4. **Content.** The zip must hold `unsigned.ipa` and `unsigned.ipa.sha256` and nothing else (`artifact-content`, 1). The IPA's SHA-256 must be the recorded one (`artifact-integrity`, 1).

   The two hashes cover different paths. `digest` comes in the API's answer and covers storage and transfer. The recorded hash covers the file from the build job to this disk, and the step summary shows it to a person.
5. **The IPA.** The checks of ADR-0013's step 6: one `Payload/<name>.app`, whose bundle ID is `bundle_id`, and no `embedded.mobileprovision`. Its version and build number must also be the ones requested (`ipa-version-mismatch`, 1).
6. **Move.** The IPA replaces `<output>/unsigned.ipa` only once every check has passed. `signed.ipa` is left alone.

`wincode_core`'s zip reader opens both archives. It refuses Zip64, which neither archive needs at these sizes; the first real run confirms that GitHub's zip opens.

**Public repositories:**

| Option | For | Against |
| --- | --- | --- |
| A. Build anyway; the reference workflow's comment only warns today | Nothing to type | Anyone with a GitHub account can download the app's IPA for a day |
| B. Refuse | Nothing leaks | Standard runners cost nothing in a public repository, whose code is public anyway |
| **C. Refuse unless `--allow-public`, and with it delete the artifact as soon as it has been checked** (chosen) | The user decides each time, in writing. The IPA is downloadable for minutes, not a day | It is still downloadable during those minutes |
| D. Encrypt the IPA on the runner | The IPA stays private even in a public repository | It needs a key on the runner, as a repository secret. Not designed here (open question 2) |

**C is chosen.**
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
    flavor:      store, scheme Store, configuration Release-store
    target:      lib/main_store.dart
    version:     2.4.0 (build_name in wincode.yaml)
    build:       58 (auto: App Store Connect's highest is 57; no run of alpha in the last 24 hours)
  Start this build on GitHub? It uses macOS minutes. [y/N]
  ```

  - Any answer but `y` or `yes` starts nothing: `build-cancelled` (1), like `upload-cancelled`.
  - `--yes` skips the question.
  - Without a terminal, with `--json` or `--events`, or in CI, a missing `--yes` is `confirmation-required` (64), before any request, as for `upload`.
- **What a caller sees of the cost:**
  - the `plan` event and the result carry the runner's label (`runsOn`), the workflow's `timeoutMinutes`, and whether the repository is `private`;
  - a `wait` event every 60 seconds carries the minutes so far;
  - the result's `minutes` gives each job's time, from its `started_at` and `completed_at`, rounded up per job, as an estimate.
- **winCode shows no prices and reads no billing data.** Prices and included usage depend on the account's plan. GitHub's timing endpoints are being closed down, and they leave the macOS multiplier out.

### 8. Template drift

**The workflow states its contract** in a line `# wincode-workflow-contract: 2`. The number counts what `build` relies on: the inputs and their meaning, the run's name, and the artifact's name and files. It changes only when one of those changes; versions, steps and comments can change without it. The current template has no such line, and counts as contract 1.

**Before the dispatch,** `build` reads the workflow file at the ref's commit:
- **Another contract number, or none:** `workflow-contract` (78), and nothing starts.
  - A contract 1 workflow does not declare the inputs `build_name`, `build_number` and `target`, and GitHub refuses a dispatch with inputs that the workflow does not declare.
  - The message gives both numbers. The next step is to replace the workflow with this winCode's reference workflow, or to update winCode if the workflow is the newer one.
- **The same contract, with other lines changed:** a WARN with the number of lines that differ from winCode's template. The values that a user is expected to set are blanked first: `FLUTTER_VERSION`, `XCODE_APP`, `runs-on` and `timeout-minutes`.
  - `--verbose` prints the differences, with `init`'s `diffLines`.
  - The build goes on: a changed workflow belongs to its owner, and the contract and the IPA's checks still hold.
- **The file itself:**
  - `GET .../actions/workflows/{file}` must find it (`workflow-not-found`, 78): GitHub dispatches only a workflow that is on the default branch.
  - Its `state` must be `active` (`workflow-disabled`, 78).
  - A 422 from the dispatch for an input is `workflow-input-unknown` (78), as ADR-0014 planned.
  - GitHub runs the workflow file as it is at the dispatched ref, which is the copy winCode checked. The first real run confirms this.

**winCode never writes to the app's repository.** It reads the workflow and says what differs; replacing the workflow is the user's commit. `init --workflow` still writes only a new file (open question 7).

**Contract 2 changes the reference workflow in these ways:**
- it adds the contract line;
- it takes the inputs `request_id`, `build_name` and `build_number` (required) and `flavor` and `target` (optional, empty by default), all strings. `FLAVOR` leaves `env`;
- inputs reach the shell only as environment variables of the build step (`BUILD_NAME`, `BUILD_NUMBER`, `FLAVOR`, `TARGET`), never as `${{ inputs.* }}` inside `run:`, so that no input is ever read as shell code;
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

# (permissions, the job, checkout, Xcode and Flutter as in contract 1, without FLAVOR under env)

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

**`--events`,** for `build` only, writes one JSON object per line on stdout, as things happen.
- Its last line is the same object that `--json` gives, with `"event": "result"` added.
- `--events` and `--json` together are a usage error (64), so that stdout always has one shape.
- Text for people goes to stderr in both cases.

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
| 1 | One of four things. A check before the dispatch failed, so nothing started (`build-in-progress`, `build-number-not-higher`, `bundle-id-mismatch`, …). The run failed or was cancelled. The artifact or the IPA failed a check. Or the question was answered no |
| 64 | The command line (`--all`, a commit SHA as `--ref`, `--run` with `--ref`, `--events` with `--json`), `confirmation-required`, or `repository-public` |
| 69 | GitHub or App Store Connect cannot be reached before the dispatch, or the dispatch's answer was lost (`offline`) |
| 70 | A bug |
| 75 | A run was started, or named with `--run`, and was still going when winCode stopped waiting: at `--timeout` (`run-timeout`), or after Ctrl-C (`wait-stopped`). Collect it with `--run <id>` |
| 77 | No GitHub token, or GitHub refused it (401, or a 403 that is not a rate limit). Or App Store Connect refused the key, when `build` reads it |
| 78 | The setup: no `workflow:`, `repository-not-found`, `ref-not-found`, `workflow-not-found`, `workflow-disabled`, `workflow-contract`, `workflow-input-unknown`, `scheme-missing`, `configuration-mismatch`, `target-missing`, `build-name-missing`, `build-number-missing`, `credentials-missing` |

75 was "`upload` only" in ADR-0013, and is now `upload` and `build`.

### 10. `doctor --build`

`wincode doctor --build [--app <name> | --all]` makes, for each app, every check that `build` makes before a dispatch, and starts nothing.
- Because it only reads, `--all` is allowed, with the table and exit code of ADR-0014 (section 3).
- `build` runs the same checks before every dispatch, so `doctor --build` is a preview, not a step that `build` needs.

| Check | What it shows | Result |
| --- | --- | --- |
| Settings | `workflow:` is there and well formed; `flavor`, `target` and `build_name` are valid | FAIL (78) |
| Token | Where it comes from, and its kind | FAIL `github-token-missing`. INFO for a classic token or `gh`'s login, which can do more than `build` needs |
| Repository | It can be read; its visibility and default branch | FAIL `repository-not-found`. WARN when it is public: `build` will need `--allow-public` |
| Workflow | It is on the default branch, and active | FAIL `workflow-not-found`, `workflow-disabled` |
| Ref | The commit it points to | FAIL `ref-not-found` (78) |
| Contract | The workflow at that commit has contract 2 | FAIL `workflow-contract`; WARN for other differences |
| Project | The checks of section 2 at that commit | As in section 2 |
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
     why: contract 2 adds the inputs build_name, build_number and target, which a contract 1 workflow does not declare, and GitHub refuses a run with inputs that its workflow does not declare. Nothing was started.
     next: replace .github/workflows/wincode-ios.yml with the reference workflow of this winCode version (templates/wincode-ios.yml in winCode), keep your values under env, push it to main, then run wincode build again.
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
   wincode build: no GitHub token: GH_TOKEN and GITHUB_TOKEN are not set, and gh is not installed
     why: winCode starts the workflow through GitHub's API, which needs a token with Actions (read and write) and Contents (read) on the repository.
     next: set GH_TOKEN to a fine-grained token limited to example-org/example-app with those permissions, or install gh and run gh auth login.
   ```

8. **Build in progress** (`build-in-progress`, 1):

   ```
   wincode build: a build of alpha is already running: <URL> (build 58)
     why: two runs of one app would compete for the same build number and the same output folder.
     next: collect it with wincode build --app alpha --run <id>, or cancel it at <URL>, then run wincode build again.
   ```

### 13. Implementation plan, and acceptance

The work comes in four pull requests, each of one concern:
1. **Contract 2 of the reference workflow.** The template, its embedded copy, and actionlint in CI. `init --workflow` writes it byte for byte.
2. **The GitHub client** (`lib/src/github.dart`), and the start of `doctor --build`.
   - The client covers token sources, the API version, the one host, redirects without the token, rate limits and redaction.
   - The tests use a fake GitHub server on `127.0.0.1`.
   - `doctor --build` gets its settings, token, repository, workflow and contract checks.
3. **The project at the ref.**
   - `wincode_core`'s reader with a file source, the scheme and configuration rules, and the keys `build_name` and `target` in the loader.
   - The build number: `pubspec.yaml`, given, `auto`, and the run list.
   - The rest of `doctor --build`.
4. **`build` itself:**
   - the plan, the question, the dispatch, the wait, the events, Ctrl-C, the timeout and `--run`;
   - the download, the integrity and IPA checks, and the result;
   - `--dry-run` and the goldens.

**Before any macOS minute,** with the maintainer's yes, a test repository dispatches a small Linux workflow that uploads a small file. It confirms GitHub's behaviour on cheap minutes:
- the run's ID in the dispatch's answer;
- that `display_title` is the run's name;
- what `digest` holds;
- that the zip opens with `wincode_core`'s reader;
- that the token does not follow the redirect;
- which copy of the workflow file runs.

**Accepted when** these all hold. They replace ADR-0013's phase 5 criteria and ADR-0014's additions to them.
- **Against a fake GitHub server** (no network in CI):
  - the dispatch carries every input, and the run is found from the dispatch's answer, and by its name after a 204;
  - the wait gives job and step events;
  - a failed run names its step; a cancelled run, and a run that never started, each give their own message;
  - the timeout exits 75;
  - Ctrl-C at a fake terminal: answered no, the run goes on (75); answered yes, the cancel request is sent;
  - `--run` collects a run;
  - the artifact is downloaded through a redirect that does not carry the token, and each integrity failure is reported;
  - a public repository is refused, and with `--allow-public` the artifact is deleted.
- **No paid run on a failed check.** Each check before the dispatch fails with no dispatch request: the fake server fails the test if it gets one. The checks are the contract, the scheme, the configuration fallback, the bundle ID, the target, the build number not higher, a build in progress, a public repository and a missing confirmation.
- **Two apps of one workflow** start two runs, each with its own inputs and app tag.
- **`--dry-run` sends no request:** a server that fails on any request proves it.
- **`--events`:** golden lines, each line valid JSON, and the last line equal to `--json`'s object.
- **No secret in any output,** `--verbose` included: no token, no signed link, no `Authorization` header.
- **The template:** it passes actionlint, and `init --workflow` writes it byte for byte.
- **The real run:** `wincode build`, `wincode sign` and `wincode upload` of one app of a file of apps, in a row, end with a build processed as valid. It uses macOS minutes and an upload, with the maintainer's yes. It also confirms whether `GET /v1/apps/{id}/buildUploads` lists uploads.

### 14. Out of scope, and open questions

Out of scope:
- `ship` and `--then` (section 1);
- `--all` for `build`;
- GitHub Enterprise Server;
- a Flutter project that is not at the repository's root;
- Flutter and Xcode versions per app (already out of scope in ADR-0014).

Open questions for the maintainer:
1. **Variants with one bundle ID.** Should a DEV flavor that ships under the store app's record be allowed in the same file? It could be, for example, `variants:` under an app, chosen with `--variant`. Or should it stay a second file chosen with `--config`?
2. **Public repositories.** After the download, is deleting the artifact enough, or should winCode also delete the run, with its log and inputs? Should the IPA be encrypted on the runner with a key kept as a repository secret? Or should public repositories be refused outright, with no flag?
3. **`auto` by default.** Should `auto` be the default in a file of apps, where `pubspec.yaml`'s one number fits no app's sequence? And is 24 hours the right window for the runs that hold a number?
4. **One token,** or a token per repository (for example `GH_TOKEN_<OWNER>_<REPO>`), for a server that builds apps of several organisations?
5. **`--events` for `sign` and `upload`,** so that a calling tool follows the whole lane in one way?
6. **GitHub Enterprise Server:** another API host, and `GH_ENTERPRISE_TOKEN`?
7. **Updating the workflow.** Should `init --workflow --force` replace an existing workflow while keeping the values under `env`? Should winCode print its reference workflow instead? Or should it do neither?
8. **The wait.** Is 60 minutes the right default for `--timeout`? Should winCode ever cancel a run itself, for example at the timeout?
9. **Cost.** Are minutes per job enough for a calling tool, or should winCode estimate a price from a rate that the user sets?
10. **`ship`.** When should it come, and should it keep a record of the steps so that a second run can resume?
11. **The question before the dispatch.** Should it be y/N, or the app's name typed in full, as `upload` asks? A build spends money, but it takes nothing that cannot be given back.

## Consequences

- **No command needs `gh` any more.** It is one of three places a token can come from. A Linux server needs `wincode` and `GH_TOKEN`; a desktop user logged in to `gh` needs nothing new.
- **winCode holds a GitHub token,** in memory, during `build` and `doctor --build`. ADR-0013's "winCode holds no GitHub token at all" (section 7) gives way to the rules of section 5.
- **Each repository updates its workflow to contract 2** before `build` works there. Repositories that copied the reference workflow with `init --workflow` copy it again and keep their values under `env`. No `build` has run yet, so no existing run breaks.
- **ADR-0014's phase 5 changes:**
  - `build_number` is always sent, and the workflow requires it;
  - `build_name` and `target` are new inputs, reserved in `workflow_inputs`, which holds at most 20 entries;
  - `configuration` is read by `build` too;
  - the version per app, which ADR-0014 (section 8) left out of scope, is now `build_name`.
- **`build` reads App Store Connect** when the app has credentials, with GET requests only, to check the build number. Without credentials it still runs, except with `auto`.
- **A public repository needs `--allow-public`,** where ADR-0013's reference workflow only warned.
- **The run list on GitHub shows** a hash of each app's bundle ID, its version and its build number. None of them is secret, and no app's name appears.
- **Cost stays visible:** a question before every paid run at a terminal, `--yes` in automation, and the minutes per job in the result.
- **To revisit:**
  - the open questions;
  - flutter_tools' scheme and configuration rules, each time the template moves to a new Flutter;
  - what the Linux rehearsal and the first real run confirm (section 13).

## Alternatives considered

- **`gh`, a GitHub App, or OAuth's device flow:** section 5.
- **Finding the run only by its name:** this was ADR-0013's plan, and it is still the fallback for an answer without a run ID. The dispatch's answer names the run, without a race against other runs of the same workflow.
- **`repository_dispatch`:** it needs Contents write on the repository, it runs only from the default branch, and it returns no run.
- **Webhooks:** they need a server that GitHub can reach. Polling is enough for one run.
- **`concurrency:` in the workflow, against two builds of one app:** when a new run joins a group, GitHub cancels the run already waiting in it, so a paid run can be lost. It does nothing for the build number either. The run list refuses before anything starts.
- **A counter file for build numbers,** in the repository or on disk: that means a commit for every build, or a file to keep in step between machines.
- **Reserving the number at Apple** by creating the build upload before the build: a write to Apple before anything is built, and a record left behind when the build fails.
- **`--dart-define` for the version, the number or the entry point:** some projects refuse it, and Flutter has options of its own for all three.
- **Checking the local checkout instead of the ref:** section 2.
- **An online `--dry-run`:** it would break ADR-0013's promise that `--dry-run` sends nothing, on which scripts rely. `doctor --build` is the online preview.
- **NDJSON under `--json`:** `--json` means one object for every command, and callers rely on that.
- **The recorded hash alone, or `digest` alone:** each covers only one path (section 6).
- **The hash read from the job's log:** that is another path for the hash, but the log is the build's whole output, in a form that winCode does not control.
- **An unzipped artifact (`archive: false` in `upload-artifact`):** GitHub documents the download as a zip only.
- **GitHub's billing API, for real costs:** it needs billing permissions on the account, far beyond what a build needs.

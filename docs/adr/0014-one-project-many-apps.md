# 0014. One project, many apps

- Status: Accepted
- Date: 2026-11-09
- Amended: 2026-11-09, after review: the keys root is on the Windows side, not on the WSL2 disk (section 2); `init` edits a file of apps in place with `yaml_edit` (section 5); names of apps and references may not be common words or shorter than 3 characters, and paths derived from the config are redacted (section 4)
- Amends: ADR-0013 (sections 1, 2, 3, 4 and 7, and the acceptance criteria of its phases 2 to 5). Design only: nothing here is implemented yet.
- Implementation: pull requests 1 (schema and loader) and 2 (credentials resolution) of section 11 are built, see "As built" there; pull requests 3 and 4 are not started.

## Context

- **A white-label project ships several App Store apps from one codebase:** one Flutter project, one flavor per app, one app record per app. Two apps of such a project can differ in every value that winCode signs and uploads with: the bundle ID, the Apple team, the App Store Connect account and so its API key, the distribution certificate and its private key, the profile, the entitlements, and the sequence of build numbers, which App Store Connect keeps per app record.
- **ADR-0013 describes one app per file.** `wincode.yaml` holds one bundle ID and one team ID, and "a project with flavors keeps one file per flavor that ships, chosen with `--config`" (section 2). The keys come from two environment variables, `WINCODE_ASC_KEY_DIR` and `WINCODE_DIST_KEY`, one of each per shell.
- **That holds for one app and breaks for several:**
  - The variables belong to the shell, not to the file. Between an app of one team and an app of another, the user has to change both, and a forgotten change sends one team's key with the other team's app. Apple refuses it, after a run that looked right until then.
  - Nothing compares the files. Two of them can name the same bundle ID, or the same output folder, where one app's `signed.ipa` replaces the other's.
  - Nothing in a file says which flavor it is. `init --flavor` reads `Release-<flavor>` and records the values it found, not the flavor ("`init` as built"), and the reference workflow builds the flavor written into the workflow file (`FLAVOR` under `env`), so one workflow cannot build several apps.
  - A program that drives several apps has to keep a file and two variables per app in step.
  - Redaction hides the bundle ID and the team ID. The flavor, the folder and file names and the app's short name are often the client's brand, and they are printed as they are.
- **The code as built** (`main` at 54d56bb): `loadConfig` and `parseConfig` in `packages/wincode_cli/lib/src/config.dart` read one flat map of six keys, refuse an unknown key and a secret-looking one, and need every value to be text. `preflight` reads its key folder from `WINCODE_ASC_KEY_DIR`, refuses it in OneDrive, and checks each of its files with `requireOutsideGit`. `init` writes a flat file, and replaces one only with `--force` after printing the diff. The `Redactor` replaces each registered value as a substring, one value after another.

## Decision

### 1. Schema: `apps:`, with optional `defaults:`

| Option | For | Against |
| --- | --- | --- |
| A. One file per app, as now, plus a credentials reference | No new shape | No check across apps (bundle IDs, output folders); the user and any program still keep N files in step |
| B. A list: `apps: [{name: alpha, ...}]` | The order is written down | A name is unique only by an extra check; a list of maps is harder to read and to diff |
| **C. A map from name to app, and optional `defaults:`** (chosen) | A name is unique by construction: the YAML reader refuses a repeated key (`Duplicate mapping key`). The values that apps share are written once | The loader reads two shapes, since the flat one stays |

**C is chosen.** The worked example (section 9) shows a whole file.

- **Two shapes.** A file whose top level has `apps` is a *file of apps*: its top level holds `apps` and, optionally, `defaults`, and nothing else. A file without `apps` is a *flat file*, read exactly as ADR-0013 reads it: one app without a name. Every flat file that is valid today stays valid with the same meaning, and every message about one stays as it is. A file that mixes the two (`bundle_id` next to `apps`) is refused, so that no value is read from the wrong level.
- **One set of app keys** for a flat file and for each entry under `apps`:

| Key | Required | In `defaults` | What it is, and what the loader checks |
| --- | --- | --- | --- |
| `bundle_id` | yes | no | As ADR-0013. Unique across the apps of the file, ignoring case |
| `team_id` | yes | yes | As ADR-0013 |
| `flavor` | no | no | The Flutter flavor that builds this app: `init` reads `Release-<flavor>` for it, and `build` passes it to the workflow (section 6). One to 64 letters, digits, `_` and `-`, starting with a letter or digit |
| `configuration` | no | no | The Xcode build configuration that `init` reads, when it is not `Release-<flavor>` (for example `Release-Alpha` for the flavor `alpha`). Read by `init` only. One to 64 letters, digits, spaces, `.`, `_` and `-` |
| `profile` | for `sign` | no | As ADR-0013. A path, hidden by `--redact` (section 4) |
| `entitlements` | when the app has a file | yes | As ADR-0013 |
| `workflow` | for `build` | yes | As ADR-0013 |
| `workflow_inputs` | no | yes | Extra inputs that `build` passes to the workflow, a map from name to text (below) |
| `output` | no | no | As ADR-0013. Default: `build/wincode/<app>` in a file of apps, `build/wincode` in a flat file. Two apps may not resolve to the same folder (compared ignoring case, as on Windows) |
| `credentials` | in a file of apps | yes | The name of a credentials reference (section 2). In a flat file it is optional, and without it the two variables of ADR-0013 apply |

- **`flavor` and `configuration` answer two questions,** so both may be written: what Flutter builds (`flavor`), and where `init` reads the IDs (`configuration`, which defaults to `Release-<flavor>`, or to `Release` without a flavor; the command-line flags combine the same way, `--configuration` overriding the default, section 5). This replaces ADR-0013's bullet "The build configuration is not a setting": in a file of apps, the entry is the only thing that ties a name to a build, and `build` needs the flavor.
- **`defaults`** holds the keys of the third column. An app's own value replaces the default whole, a map included (`workflow_inputs` is not merged key by key), so that an entry shows the complete value of every key it writes. A key that is per app by nature (`bundle_id`, `flavor`, `configuration`, `profile`, `output`) is refused in `defaults` with a message that says so. YAML merge keys (`<<: *name`) are refused as an unknown key: `defaults` is the one way to share values.
- **Names of apps and of credentials references:** 3 to 32 characters, lower-case letters, digits and `-`, starting with a letter and ending with a letter or digit (`^[a-z][a-z0-9-]{1,30}[a-z0-9]$`). Refused besides: the common words of section 4 (`build`, `key`, `app`, `release` and the rest of the list, so that redacting a name never hides an ordinary word), the Windows device names (`con`, `prn`, `aux`, `nul`, `com1` to `com9`, `lpt1` to `lpt9`) and the shapes of the placeholders of section 4 (`app-<digits>`, `credentials-<digits>`, `flavor-<digits>`, `configuration-<digits>`). Why: a name becomes a folder name (`build/wincode/<app>`, `<WINCODE_KEYS_DIR>/<reference>`) on a file system that ignores case, and part of a variable name, so it has one spelling; and a placeholder printed by `--redact` must never also be a real name.
- **Unknown and secret-looking keys** are refused as today, at every level: the top level, `defaults`, each app, and the names in `workflow_inputs`. `credentials` is a known key, although its name contains `credential`. Its value is a name under the rule above, which cannot hold a key: a `.p8` has spaces and line breaks, a Key ID has capital letters, and an Issuer ID has 36 characters.
- **`workflow_inputs`:** each name is 1 to 32 lower-case letters, digits and `_`, starting with a letter, and is not `request_id`, `flavor` or `build_number`, which `build` sets itself. Each value is text of at most 64 letters, digits, `.`, `_`, `-` and `/`. This is the one field whose values have no fixed meaning, so the rule is narrow and the reason is in the message: an input of a dispatched run is shown on the run's page and in its log to everyone who can read the repository, so it is never a place for a secret, which belongs in the repository's Actions secrets.
- **One credentials reference, one team.** A reference that apps with different `team_id` values name is refused: Apple issues an API key and a distribution certificate to one team, so one of those apps would fail at Apple. Two references for one team are allowed, for example for apps signed with different distribution certificates.
- **The whole file is checked** whichever app a command works on, so that a broken entry shows on the first run, and so that the checks across apps (bundle IDs, output folders, references and teams) can be made at all. A message names the line and the key, never the value, as ADR-0013 says.

### 2. Credentials: a reference per app, one root folder on the Windows side

| Option | For | Against |
| --- | --- | --- |
| A. Paths of the key files in `wincode.yaml` | One file says everything | The file goes with the project, and paths show user names and folder layouts; ADR-0013 keeps every key and key folder out of it |
| B. Two variables per app (`WINCODE_ASC_KEY_DIR_ALPHA`, ...) | Nothing new to learn | Two apps of one team need the same setting twice; app names end up in the environment of every program |
| **C. A credentials reference per app; one keys root on the Windows side, with a subfolder per reference; a variable per reference and key that overrides the folder** (chosen) | Apps of one team share one folder; the file holds a name only; no setting needed on a PC that uses the default; `preflight` never needs WSL2 | A layout to learn, and a third variable next to the two old ones |
| D. Windows Credential Manager, an entry per reference | Keys out of plain files | ADR-0013 defers the credential store, and zsign reads a file anyway |
| E. The root on the WSL2 disk (the first draft of this ADR) | The key never sits on a Windows drive | `preflight`, `upload` and `status` would need WSL2 running and read the key through `\\wsl.localhost`; the keys would live in a distribution that a lost disk destroys (it happened on 2026-10-17, `docs/PLAN.md`) and that `wsl --export` copies; the git and OneDrive checks would have to reach into WSL2. Rejected after review |

**C is chosen.** The layout, with fixed names:

```
<keys root>/
  <reference>/
    AuthKey_<Key ID>.p8    the App Store Connect API key, as App Store Connect delivered it
    issuer-id              one line: the Issuer ID
    dist.key               the distribution private key (PEM), as ADR-0013 section 4 describes it
```

- **The IDs are found as `preflight` finds them today:** the Key ID from the name `AuthKey_<Key ID>.p8`, the Issuer ID from the file `issuer-id`. Neither is in `wincode.yaml` or in a variable. A reference folder holds exactly one `.p8`, as today's key folder does. So a reference folder is today's `WINCODE_ASC_KEY_DIR` folder plus `dist.key`, the name the spike gave the key (`docs/spikes/spike-c-store-acceptance.md`).
- **The keys root is on the Windows side, never on the WSL2 disk.** It is `%USERPROFILE%\.wincode\keys` unless `WINCODE_KEYS_DIR` names another folder, which is a folder on a Windows drive. Nothing key-related is written inside WSL2, and `preflight`, `upload` and `status` never need WSL2. `sign` reads `dist.key` in place: zsign gets its path as `wslpath -u` translates it (`C:\Users\<user>\.wincode\keys\team-one\dist.key` becomes `/mnt/c/Users/<user>/.wincode/keys/team-one/dist.key`; ADR-0013, section 4). A root that `wslpath` cannot translate (a network share, a drive that WSL2 does not mount) still serves `preflight`, `upload` and `status`, and `sign` fails with `dist-key-unreachable` (78). winCode sets no permissions: the folder inherits those of the profile folder, which by default exclude other standard users.
- **A variable per reference and key** overrides the folder, for CI and for keys kept elsewhere:

  | Variable | Replaces | Read like |
  | --- | --- | --- |
  | `WINCODE_ASC_KEY_DIR_<REF>` | `AuthKey_<Key ID>.p8` and `issuer-id` of the reference | `WINCODE_ASC_KEY_DIR`: a folder with those two files |
  | `WINCODE_DIST_KEY_<REF>` | `dist.key` of the reference | `WINCODE_DIST_KEY`: a file on a Windows drive |

  `<REF>` is the reference's name in capital letters with `-` written as `_` (`team-one` gives `TEAM_ONE`). No two names give the same suffix, since a name holds no `_`. Each variable replaces its own half only: with `WINCODE_ASC_KEY_DIR_TEAM_ONE` set, the App Store Connect key comes from there and `dist.key` still from the root. A CI job writes its secrets to files in the runner's temporary folder, outside the checkout, and sets either the root or the variables it needs; an upload-only job needs no `dist.key`.
- **Resolution, for each half:** the variable of the reference; else the file in `<keys root>/<reference>/`; else `credentials-missing` (exit 78, section 10). For an app without `credentials`, which only a flat file can have, `WINCODE_ASC_KEY_DIR` and `WINCODE_DIST_KEY` apply exactly as in ADR-0013. In a file of apps those two are never read, and when one is set, the `credentials-missing` message says that it serves only a file without `credentials`, so that a variable left over from before does not puzzle anyone.
- **The git rule for the keys root,** stricter than ADR-0013's rule for single files:
  - The root, and every folder and file that a variable of a reference names, lie outside every git working tree. A `.gitignore` entry is no exception. It is stricter than the single-file rule that `WINCODE_ASC_KEY_DIR` and `WINCODE_DIST_KEY` keep because one root holds the keys of every team in the file, is found by its default place rather than named per file, and has no reason to be inside a project, while the legacy rule must not stop a setup that works today.
  - The risk it answers: a project folder is the one that gets zipped, copied for a colleague or synced, and `git add -f` adds an ignored file anyway, so one line of `.gitignore` would stand between all of those keys and a push (`keys-in-git-tree`, exit 78, section 10).
  - Checked with `git rev-parse --is-inside-work-tree` (Git for Windows), once per run in the root, and again in the folder of each file before it is read, so that a repository inside the root (a reference folder that someone made a repository) is found too. `git check-ignore` is not asked. When git cannot answer, the folder is refused (`git-unavailable`, exit 69), as ADR-0013 fails closed.
  - A root or folder in OneDrive is refused, as `preflight` refuses `WINCODE_ASC_KEY_DIR` there today.
  - `WINCODE_ASC_KEY_DIR` and `WINCODE_DIST_KEY` keep ADR-0013's rule, ignored files included.
  - Messages name the variable and the reference, never a path, and the absolute path of the root and of each folder is registered as a secret, as the key folder's is today.
- **Migration from the two variables:**
  1. Nothing has to change. A flat file without `credentials` keeps reading `WINCODE_ASC_KEY_DIR` and `WINCODE_DIST_KEY`, with no end date; a later decision may set one.
  2. To move: make `%USERPROFILE%\.wincode\keys\<reference>`; move, not copy, into it the `.p8` and `issuer-id` from the folder that `WINCODE_ASC_KEY_DIR` names, and the file that `WINCODE_DIST_KEY` names, renamed `dist.key`; add `credentials: <reference>` to the app (a flat file may have it too); unset the two old variables, and set `WINCODE_KEYS_DIR` only for another root. A key that lies on the WSL2 disk is copied out through `\\wsl.localhost\<distribution>\...` and then deleted there. `wincode doctor` checks the result without sending anything (section 3).
  3. `init` never reads, moves or copies a key. When it writes `credentials`, its next steps print step 2.

### 3. Choosing the app: `--app`, `--all`

`--app <name>` is a global option, like `--config`, accepted before or after the command.

| The file | Without `--app` | `--app <name>` | `--all` |
| --- | --- | --- | --- |
| Flat | its one app | refused (`app-flat-file`, 64), except by `init`, which proposes the migration (section 5) | its one app |
| Of apps, one app | that app | that app; another name is `app-unknown` (64) | that app |
| Of apps, several | `app-required` (64), listing the names | that app; another name is `app-unknown` (64) | every app, in file order |

`--app` together with `--all` is a usage error.

**No default app,** as the maintainer leaned:

| Option | Against |
| --- | --- |
| A `default_app:` key | `wincode upload` without `--app` would act on one app of several, chosen by a line that the person typing the command may not see |
| A `WINCODE_APP` variable | The same, and the choice is invisible in the command line and in a CI log |
| The first app of the file | The same, and reordering the file changes what a command does |
| **None** (chosen) | Naming the app costs a few characters; a script names it anyway |

A file of apps with one app needs no `--app`, since there is nothing to choose.

**`--all` is for read-only commands:** `preflight` and `doctor`, and `status` once phase 4 builds it, since it sends only GET requests. The apps run one after another in file order, and a failure does not stop the next one. Each app's report is printed under a line `== <app> ==`, then a summary table (section 9). The exit code is that of the first app in file order that failed, else 0, as ADR-0013 takes the first failure within one command; the `--json` object holds every app's result (section 7). `--all` takes no IPA argument: each app's default IPA is checked.

**`--all` is refused for `sign`, `upload`, `build` and `init`** (`all-not-allowed`, 64). Each of them writes: `sign` a file, `upload` to Apple (never retried, ADR-0013 section 7), `build` a run on a paid macOS runner, `init` the settings. A loop inside winCode would turn one wrong setting into N wrong results, and a stop halfway would leave some apps uploaded and others not, with nothing that records which. A script that runs one app at a time with `--app` sees each result and decides what to do next (section 7). What `--all` for those commands would need, in a later decision of its own:

- a plan printed before anything runs: what each app would send or start, as `--dry-run` shows it;
- a choice of what a failure does (stop, or go on with the next app), made by the user, not defaulted;
- a record, per app, of what was written, read by the next run, so that a rerun never uploads an app twice;
- a limit on macOS runs started at once;
- a summary that says, per app, what reached Apple or GitHub.

**`doctor`.** The Mach-O check (`--binary`) reads no settings and refuses `--app` and `--all`. Without `--binary`, `doctor` checks the setup of the chosen app or apps and sends nothing: the settings load and the app is found (`settings`), and its credentials resolve: the folder or variable is there, it holds exactly one `AuthKey_<Key ID>.p8` and an `issuer-id` with an Issuer ID, both lie outside git working trees and outside OneDrive (`credentials`). Phase 3 adds that `dist.key` is there and that `wslpath` can translate its path, and the zsign checks of ADR-0013 section 4. This is ADR-0013's "each later phase adds the checks of its own setup", made per app.

### 4. Redaction of names and paths

- **What is hidden.** Besides the bundle IDs and team IDs of ADR-0013, the loader registers, for every app in the file and not only the chosen one (a message may name another app): the app names, the credentials references and their variable form (`TEAM_ONE`), the flavors and the configurations, and the paths derived from the config: `profile`, `entitlements` and `output`. They are hidden as the IDs are: with `--redact`, when `CI` is set, and always in text meant for an issue report (`forReport`, the message of an internal error).
- **Names that cannot be words.** An app name and a credentials reference must have 3 to 32 characters and must not be a common word, so that replacing them never hides a word that has another meaning in the output. The loader refuses these with `config-invalid` and a message that says which rule: at least `build`, `key`, `keys`, `app`, `apps`, `test`, `release`, `debug`, `profile`, `sign`, `upload`, `config`, `default`, `all`, and also the names of winCode's own commands and keys that the output prints (`defaults`, `init`, `doctor`, `preflight`, `status`, `team`, `credentials`, `output`, `workflow`, `entitlements`, `flavor`). The list is a constant in the loader, and an addition to it is a change to this ADR. A flavor or a configuration comes from the Xcode project and is not refused; one that is on the list or shorter than 3 characters carries no brand, so it is not replaced on its own (`Release-alpha` as a whole configuration still is).
- **Placeholders,** stable for a given file on every run and every PC:
  - `app-<n>`, where `n` is the app's place in the file, from 1;
  - `credentials-<n>`, numbered in the order in which the apps, in file order, first use them (a reference in `defaults` counts where the first app that inherits it stands), and `CREDENTIALS_<n>` for its variable form;
  - `flavor-<n>` and `configuration-<n>`, with the app's number;
  - in a file of apps, `<bundle ID 1>`, `<bundle ID 2>` and so on with the app's number, and `<team ID 1>`, `<team ID 2>` in order of first use; a flat file keeps `<bundle ID>` and `<team ID>`;
  - **paths:** `<profile of app-1>`, `<entitlements of app-1>` and `<output of app-1>`, and in a flat file `<profile>`, `<entitlements>` and `<output>`. A path that several apps share (a value of `defaults`) is named for the first app that has it. The loader registers the path as written in the file, with `/` and with `\`, and as resolved against the file's folder. A path below one of them keeps its tail: `build/wincode/alpha/signed.ipa` becomes `<output of app-1>/signed.ipa`. A path that is the profile as configured is hidden whole, so its file name, which often holds the brand, goes with it.

  Reordering the apps renumbers them; nothing else does.
- **Names are replaced as whole words, ignoring case:** where the character on each side is not a letter or digit, so the start and end of the text, `.`, `-`, `_`, `/` and spaces are edges. `Release-alpha` becomes `Release-app-1`, and `Alpha_AppStore.mobileprovision`, when it is not the configured profile, becomes `app-1_AppStore.mobileprovision`, while `alphabet` stays. IDs and paths are replaced as substrings, as IDs are today.
- **One pass.** Every registered value is replaced in a single pass over the text, the longest first, so that a placeholder is never replaced again and a path wins over the name inside it. Today's redactor replaces one value after another, and an app called `bundle` would turn `<bundle ID>` into `<app-1 ID>`.
- **The limit:** winCode hides what it knows. A brand in a file name or a path that is not one of the registered values, or in the workflow's repository, is printed as it is, with or without `--redact`.
- **A name typed by the user** that is not in the file (`app-unknown`) is not printed when redaction is on.

### 5. `init` with several apps

**Options:** `--app <name>` (global) chooses the entry; `--credentials <reference>` is new and gives its reference, which is asked at a terminal and required in a file of apps. `--flavor` and `--configuration` may now be combined: `--flavor` names the flavor to record, and the configuration to read is `Release-<flavor>` unless `--configuration` names another, which overrides that default. As built (ADR-0013), giving both is a usage error; that rule goes in implementation pull request 3, because the two keys answer two questions (section 1). From then on `init` records `flavor` when `--flavor` is given, and `configuration` when `--configuration` names another configuration than that default, in a flat file too.

| The file at `--config` | `init` without `--app` | `init --app <name>` |
| --- | --- | --- |
| None | A flat file, as built | A file of apps with that one app |
| Flat | As built: the diff, and `--force` to replace it | The migration below |
| Of apps | `app-required` (64) | Adds the entry, or updates it with `--force`, in place |

**Writing a file of apps.**

| Option | For | Against |
| --- | --- | --- |
| **A. Edit in place with `yaml_edit`** (chosen) | Comments and layout of every other line survive; the diff shows only the lines that change | A new dependency in the CLI, for one command |
| B. Render the whole file again | No new dependency; `init` already renders the flat file | Hand-written comments are dropped |
| C. Append the new entry as text | Small | Breaks on any layout but the one `init` writes |

**A is chosen,** and B is kept for the two cases that need it: a new file, and the migration of a flat file (below), whose backup holds the original with its comments.

- **Planned dependency: `yaml_edit`.** The Dart team's package (`dart-lang/tools`, `pkgs/yaml_edit`), BSD-3-Clause, pure Dart, which itself depends on `collection`, `meta`, `source_span` and `yaml`, the last of which the CLI already uses. Reason: it edits a YAML text and keeps the comments, the order and the layout of what it does not touch, which is what a person who annotates `wincode.yaml` expects from a command that adds an app. It is added in implementation pull request 3 at a version checked then, used by `init` only, and the loader stays on `yaml`. Its licence is compatible with the repository's MIT licence.
- **What an edit does.** `defaults` and the other apps keep their text and their order; `init` adds the entry under `apps:`, or sets the keys it found in the existing entry, never creates or edits `defaults`, and leaves out of an entry a value equal to the one it inherits. The edited text passes the loader before it is written, and a file that the editor cannot edit safely stops the run with the reason and no change.
- **Confirmation.** `init` changes an existing file only after it has printed the diff, and only after a yes to the question at a terminal, or `--yes` where it cannot ask. Replacing values that an entry already has also needs `--force`, as for a flat file today; adding an entry does not.
- **The migration,** for `init --app <name>` on a flat file. Never silent:
  1. `init` reads the Xcode project for `<name>` as above (`--flavor`, `--configuration`, `--bundle-id`).
  2. If the bundle ID it finds is the flat file's `bundle_id`, the flat file is this app, and `init` proposes a file of apps with one entry, `<name>`, holding the flat file's values unchanged, plus `flavor`, `configuration` and `credentials`. The output stays where it was: a flat file without `output` gets `output: build/wincode` in the entry, so that the IPAs and the scripts that read them do not move. This is the one full rewrite: the shape changes, so the file is rendered again, and its comments are in the backup.
  3. If the bundle ID differs, the flat file describes another app, and `init` stops (`config-is-another-app`, exit 1): "wincode.yaml describes another app; name it first with wincode init --app <its name> --flavor <its flavor>, then add <name> with a second run". One change per run, and no app is named after a guess.
  4. It prints the diff and asks at a terminal; elsewhere it needs `--yes` (else `init-input-missing`, 64, and nothing is written). `--force` is not enough on its own: it means "replace this file", and a migration changes the file's shape.
  5. Before writing, it copies the flat file byte for byte to `<file>.bak` next to it, such as `wincode.yaml.bak`. If that file exists, `init` stops (`backup-exists`, exit 1) and never replaces a backup. The new text passes the loader before it is written, as today, and `--json` names the backup in `backup`. The backup holds no secret, since the flat file holds none.
  6. `--dry-run` prints the diff and writes nothing, no backup either.
  7. Its next steps add the move of the keys (section 2, migration step 2) when the file had no `credentials`.

### 6. What changes in the phases of ADR-0013

**Phase 2, `preflight` and `init` (built).** `preflight` reads the App Store Connect key of the chosen app (section 2) instead of `WINCODE_ASC_KEY_DIR`, which stays for a flat file without `credentials`; its default IPA is `signed.ipa` in the app's output folder; `key-location` adds the root rule. Everything else in "Phase 2 as built" holds. `init` changes as section 5 says. Added acceptance criteria, met by pull requests 1 to 4 of section 11:

- every flat file of the phase 2 tests loads as before, and `preflight`'s goldens are unchanged; `init`'s change only where `--flavor` or `--configuration` is given, by the keys it now records;
- `preflight --app` reads only the chosen app's reference, and a test with two references makes the other one's folder unreadable;
- `preflight --all` prints each app's report, the table and the exit code of section 3, with a test where the first and the last app fail with different codes;
- a run with `--redact`, and one with `CI` set, prints no app name, reference, flavor, configuration, or profile, entitlements or output path, in the text, in the table and in `--json`;
- `preflight` runs to its end with a process runner that fails the test if `wsl.exe` is started: it never needs WSL2;
- the migration of section 5 writes a byte-identical backup, and the new file gives every value the flat file gave (bundle ID, team ID, profile, entitlements, workflow, output).

**Phase 3, `sign`.** Only the key resolution changes: the distribution key is `WINCODE_DIST_KEY_<REF>` of the app's reference, else `dist.key` in its folder of the keys root, translated by `wslpath -u` and read in place, or `WINCODE_DIST_KEY` for a flat file without `credentials`. Section 4 of ADR-0013 reads "a distribution certificate for the app's distribution key (ADR-0014, section 2)" where it reads "for the key in `WINCODE_DIST_KEY`". The checks, zsign, its pin, the password rule and the open risk of the working key are unchanged. Added acceptance criteria:

- a test for each way to the key: the variable of the reference, `dist.key` in the root through a fake `wsl.exe` for `wslpath`, and `WINCODE_DIST_KEY` for a flat file;
- a `dist.key` whose path `wslpath` cannot translate (a network share, a drive that WSL2 does not mount) fails `sign` with `dist-key-unreachable` (78; next step: move the root to a local drive, or set `WINCODE_DIST_KEY_<REF>` to a file on one) and does not affect `preflight`;
- nothing is written inside WSL2: a test with a fake runner finds no command that creates or copies a key file there;
- the certificate's status request (`GET /v1/certificates`, phase 3's) is signed with the App Store Connect key of the same reference;
- signing one app never opens another reference's folder (a test makes it unreadable);
- `sign` needs `--app` in a file of several apps, refuses `--all`, and reads `unsigned.ipa` and writes `signed.ipa` in the app's output folder.

**Phase 4, `upload` and `status`.** The App Store Connect key comes from the app's reference, as for `preflight`. `upload --app <name>` runs the strict `preflight` of that app. `status --app <name>` shows that app's uploads, and `status --all` every app's, with the table, exit code and `--json` of `preflight --all`. Added acceptance criteria:

- with two apps of two references, the fake server checks that every token carries the Key ID of the app's own reference;
- `upload` refuses `--all`; `status --all` has the golden table and object;
- the real upload of phase 4 is of one app of a file of apps, with the maintainer's yes.

**Phase 5, `build`.** The flavor becomes an input of the workflow, and each run builds one app:

- The reference workflow gets two optional string inputs, default empty: `flavor`, which replaces the `FLAVOR` value under `env`, and `build_number`, which, when set, it passes to `flutter build ipa` as `--build-number`. Its run name (`wincode <request_id>`) and its artifact (`unsigned-ipa`) stay: the run is found by its `request_id`, and one run builds one app, so the artifact's name cannot collide, and the app's name stays out of the list of artifacts.
- `build` sends `-f flavor=<flavor>` only when the app has a flavor, `-f build_number=<n>` only with the new `--build-number <n>`, one `-f` per `workflow_inputs` entry, and nothing else. A flat file without `flavor` starts the same run as before.
- **Build numbers per app:** App Store Connect keeps one sequence per app record, and `preflight` already compares with the builds of the app's own record, so nothing else changes there. `pubspec.yaml` holds one build number for every flavor, so an app whose sequence runs ahead of the others gets its number from `--build-number`; `preflight` prints the highest number so far (`builds`).
- The IPA goes to `unsigned.ipa` in the app's output folder and is checked against that app's `bundle_id` (ADR-0013, section 3, step 6).
- `build` starts one run per command and refuses `--all`.

Added acceptance criteria: against a fake `gh`, two apps of one workflow start two runs, each with its own flavor, each found by its own `request_id`; a workflow without the `flavor` input, which GitHub refuses with HTTP 422 "Unexpected inputs provided", gives `workflow-input-unknown` (78) with the next step "copy the reference workflow again, or add the input `flavor`"; the reference workflow passes actionlint and `init` writes it byte for byte, as before; the real run of phase 5 builds one app of a file of apps.

### 7. Machine use: `--json` per app

- **Every command that reads `wincode.yaml` adds `app` to its object:** the name (its placeholder when redaction is on), or `null` for a flat file. Nothing else in the objects of ADR-0013 changes, except `backup` in `init`'s after a migration (section 5).
- **`--all` gives one object** whose `apps` holds, in file order, each app's object as the command alone would print it, without `command`:

  ```json
  {"command": "preflight", "all": true, "ok": false, "exitCode": 1,
   "apps": [{"app": "alpha", "ok": true, "exitCode": 0, "checks": []},
            {"app": "beta", "ok": false, "exitCode": 1, "checks": [], "error": {"id": "build-number-not-higher"}}],
   "error": {"app": "beta", "id": "build-number-not-higher", "what": "...", "why": "...", "next": "..."}}
  ```

  `checks` is shortened here; `error` is the first failing app's error with `app` added.
- **The names in file order** are in `apps` of the `app-required` and `app-unknown` errors, so that a program can learn them without reading YAML.
- **Stable:** a field in a golden object is not renamed, removed or given another type without an amendment to this decision. New fields may be added, so a reader ignores fields it does not know.
- **An outside orchestrator** (a shell loop, a CI matrix, another program) runs one `wincode` per app and step, reads one object from stdout, and decides on `exitCode` and `error.id`:

  ```sh
  for app in alpha beta gamma; do
    wincode preflight --app "$app" --json > "preflight-$app.json"
    echo "$app: exit $?"
  done
  ```

  Runs for different apps may run at the same time: their output folders differ (section 1) and the keys are only read. Two runs for the same app at once are not supported. In CI the objects carry placeholders, and `--app` takes names only, so an orchestrator in CI keeps its own list of names (open question 1).

### 8. Out of scope, and open questions

Out of scope:

- `--all`, or any loop over apps, for `sign`, `upload`, `build` and `init` (section 3 says what it would need);
- a lock against two runs for the same app;
- a command that lists the apps (the errors of section 7 carry the names);
- a credential store (ADR-0009), per reference or not;
- creating, moving or checking keys inside `init`, or making the root;
- more than one App Store Connect key or distribution key per reference;
- a version (`CFBundleShortVersionString`) per app, for apps that do not share `pubspec.yaml`'s;
- the workflow's Flutter and Xcode versions per app.

Open questions:

1. Should `--app` accept the placeholders (`app-2`), so that an orchestrator in CI can use what the redacted output gives it? They change when the file is reordered, which is a risk for `upload`.
2. Should `build` take the next build number from App Store Connect (the highest plus one)? `build` would then need the App Store Connect key, which it does not need today.
3. When, if ever, do `WINCODE_ASC_KEY_DIR` and `WINCODE_DIST_KEY` stop working?
4. Is "one reference, one team" (section 1) always true? It holds for team API keys and distribution certificates; individual API keys should be checked against Apple's documentation before the loader refuses on it.
5. Should the strict git rule of the root (section 2) extend to ADR-0013's single files, so that one rule serves every key?

### 9. Worked example

Three apps: `alpha` and `beta` belong to one team and share the reference `team-one`; `gamma` belongs to another team and has `team-two` alone.

```yaml
# wincode.yaml: three apps of one Flutter project, no secrets. Paths are relative to this file.
defaults:
  team_id: TEAM000001
  credentials: team-one
  workflow: example-org/example-app/.github/workflows/wincode-ios.yml@main
  entitlements: ios/Runner/Runner.entitlements

apps:
  alpha:
    bundle_id: com.example.alpha
    flavor: alpha
    profile: ../signing/alpha.mobileprovision
  beta:
    bundle_id: com.example.beta
    flavor: beta
    profile: ../signing/beta.mobileprovision
  gamma:
    bundle_id: com.example.gamma
    flavor: gamma
    team_id: TEAM000002
    credentials: team-two
    profile: ../signing/gamma.mobileprovision
    workflow_inputs:
      environment: production
```

What each app resolves to:

| App | Bundle ID | Team | Credentials | Flavor | Output |
| --- | --- | --- | --- | --- | --- |
| `alpha` | `com.example.alpha` | `TEAM000001` | `team-one` | `alpha` | `build/wincode/alpha` |
| `beta` | `com.example.beta` | `TEAM000001` | `team-one` | `beta` | `build/wincode/beta` |
| `gamma` | `com.example.gamma` | `TEAM000002` | `team-two` | `gamma` | `build/wincode/gamma` |

The keys, names only, in the default root on the Windows side (`WINCODE_KEYS_DIR` is not set):

```
%USERPROFILE%\.wincode\keys\
├── team-one/              alpha and beta
│   ├── AuthKey_<Key ID>.p8
│   ├── issuer-id
│   └── dist.key
└── team-two/              gamma
    ├── AuthKey_<Key ID>.p8
    ├── issuer-id
    └── dist.key
```

Commands:

```
wincode preflight --app alpha     reads team-one's .p8 and issuer-id
wincode preflight --all           alpha, beta, gamma in turn, then the table
wincode sign --app gamma          reads team-two\dist.key in place only; writes build/wincode/gamma/signed.ipa
wincode upload --app beta         a token from team-one's key, for the app record of com.example.beta
wincode upload --all              refused: all-not-allowed (64)
```

An upload-only CI job for `gamma` sets `WINCODE_ASC_KEY_DIR_TEAM_TWO` to a folder in the runner's temporary folder that holds `AuthKey_<Key ID>.p8` and `issuer-id`, and nothing else.

The end of `wincode preflight --all`, run by a person, when beta's build number is used already and team-two's folder is missing:

```
app    result  first failure            exit
alpha  PASS                             0
beta   FAIL    build-number-not-higher  1
gamma  FAIL    credentials-missing      78
wincode preflight --all: 2 of 3 apps failed; exit 1, the first failure in wincode.yaml (beta).
```

The same in CI, where `CI` is set:

```
app    result  first failure            exit
app-1  PASS                             0
app-2  FAIL    build-number-not-higher  1
app-3  FAIL    credentials-missing      78
wincode preflight --all: 2 of 3 apps failed; exit 1, the first failure in wincode.yaml (app-2).
```

The migration, from a flat file that describes `alpha`:

```
wincode init --app alpha --flavor alpha --credentials team-one
```

shows the diff of the flat keys becoming `apps:` → `alpha:` with `flavor: alpha`, `credentials: team-one` and `output: build/wincode` added, asks, copies the flat file to `wincode.yaml.bak`, writes the new file, and prints the move of the keys. `wincode init --app beta --flavor beta --credentials team-one` then adds `beta`. Run first, on alpha's flat file, that second command would stop with `config-is-another-app`.

### 10. Messages

In the form of ADR-0013 section 6, as `preflight` prints them for the worked example. With `--redact` or `CI`, the names become their placeholders.

1. **Unknown app** (`app-unknown`, exit 64; every command that reads `wincode.yaml`):

   ```
   wincode preflight: wincode.yaml has no app named gama
     why: --app names one of the apps under apps: in wincode.yaml, spelled as there.
     next: use one of alpha, beta, gamma.
   ```

   With redaction on, the first line is `wincode.yaml has no app by the name that --app gives`, and the next step lists `app-1, app-2, app-3`.

2. **Missing `--app`** (`app-required`, exit 64):

   ```
   wincode preflight: wincode.yaml has 3 apps, and the command does not say which one
     why: each app has its own bundle ID, team, profile and keys, and winCode works on the app that the command names, so that nothing reaches the wrong app record.
     next: add --app with one of alpha, beta, gamma, or --all to check every app.
   ```

   For `sign`, `upload`, `build` and `init`, the next step ends after the names.

3. **Missing credentials folder** (`credentials-missing`, exit 78; `preflight`, `doctor`, `sign`, `upload`, `status`):

   ```
   wincode preflight: the credentials team-two of app gamma are missing: the keys folder has no folder team-two
     why: wincode.yaml names a credentials reference for each app, never a key, and gamma's App Store Connect key is read from that folder.
     next: create the folder team-two in %USERPROFILE%\.wincode\keys (or in the folder that WINCODE_KEYS_DIR names) with AuthKey_<Key ID>.p8, as App Store Connect delivered it, and issuer-id (and dist.key, for wincode sign), or set WINCODE_ASC_KEY_DIR_TEAM_TWO to a folder that holds the first two.
   ```

   When the keys folder itself does not exist, the first line ends `the keys folder does not exist` (with `WINCODE_KEYS_DIR` set, `the folder that WINCODE_KEYS_DIR names does not exist`). When `WINCODE_ASC_KEY_DIR` is set, the next step adds: `WINCODE_ASC_KEY_DIR is set, but it serves only a wincode.yaml without credentials.`

4. **Key folder inside a git working tree** (`keys-in-git-tree`, exit 78; the same commands). The rule of section 2 makes no exception for an ignored folder:

   ```
   wincode preflight: WINCODE_KEYS_DIR points inside a git working tree
     why: the folder holds the keys of every team that wincode.yaml names. A key in a working tree can be committed and pushed with the project, and it stays in the history after it is deleted. A keys folder has no reason to be in a project, so winCode refuses it there even when git ignores it.
     next: move the folder outside every git working tree, such as %USERPROFILE%\.wincode\keys, and set WINCODE_KEYS_DIR to it (or unset WINCODE_KEYS_DIR to use that default).
   ```

   For a variable of a reference, the first line names it (`WINCODE_ASC_KEY_DIR_TEAM_ONE points inside a git working tree`), and so does the next step. With `WINCODE_KEYS_DIR` unset, the first line reads `the default keys folder lies inside a git working tree`, which happens when the user profile is itself a repository.

5. **Duplicate bundle ID** (`config-invalid`, exit 78; every command that reads `wincode.yaml`), if beta's line 14 said `bundle_id: com.example.alpha`:

   ```
   wincode preflight: wincode.yaml line 14: apps beta and alpha have the same bundle_id
     why: one bundle ID is one app record in App Store Connect, so the two entries would sign and upload two different builds to it.
     next: correct the bundle_id of beta (line 14) or of alpha (line 10), or remove one of the two entries.
   ```

Other new failures, each in the same form: `app-flat-file` (64), `all-not-allowed` (64), `config-is-another-app` (1), `backup-exists` (1), `dist-key-unreachable` (78, phase 3), `workflow-input-unknown` (78, phase 5), and these variants of `config-invalid` (78): both shapes in one file, a name outside the rule (too short, or a common word), a key that `defaults` may not hold, an app of a file of apps without `credentials`, a reference used by two teams, two apps with one output folder, and a `workflow_inputs` name or value outside its rule.

### 11. Implementation plan

Four pull requests, each one concern, each leaving every command working. The credentials come before `--app`, so that `preflight` on a file of apps can read a key as soon as it can choose an app. Each adds its tests to `dart test` on Ubuntu and Windows, reaches no network, and updates `packages/wincode_cli/README.md`. No golden of a flat file changes, except `init`'s output with `--flavor` or `--configuration` in pull request 3.

1. **`feat(cli): read files of several apps in wincode.yaml (ADR-0014)`.** Schema and loader.
   - `loadConfig` and `parseConfig` read both shapes and return the apps in file order, each a `WincodeConfig` with `name` (null for a flat file), `flavor`, `configuration`, `credentials` and `workflowInputs`. Every check of section 1.
   - The `Redactor` gets names as whole words, one pass, and the placeholders of section 4; the loader registers every app's names, IDs and configured paths, and refuses names under 3 characters and common words with a message that says which rule.
   - Commands still work on one app: a flat file, or a file of apps with one app. A file of several apps exits 64 (`not-implemented`: "several apps need --app, see ADR-0014") until pull request 3.
   - Accepted when: every existing test of `config_test.dart` passes unchanged; each rule of section 1 has a test and its message a golden (message 5 included); each word of the common-word list, and a two-character name, is refused; duplicates are found ignoring case; the redaction tests cover whole words, case, one pass, an app named `bundle`, placeholders in file order, the path placeholders (`<profile of app-1>`, a tail kept after `<output of app-1>`, a path shared through `defaults`), `forReport`, and every kind of write to the sink.
2. **`feat(cli): resolve each app's keys through a credentials reference (ADR-0014)`.**
   - `WINCODE_KEYS_DIR`, the variables of each reference, and the old two for a flat file without `credentials`, as section 2 says; the root rule; OneDrive; messages 3 and 4.
   - `preflight` uses it; `doctor` without `--binary` checks `settings` and `credentials` (section 3).
   - Accepted when: in a real repository in a temporary folder, a root inside it is refused, ignored or not, and a repository inside a root outside is found; each half takes its variable first; each missing case gives its message; no output holds a path, a Key ID or an Issuer ID; with no `WINCODE_KEYS_DIR`, the default root `%USERPROFILE%\.wincode\keys` is used; `preflight` starts no `wsl.exe`; the existing `preflight` tests pass unchanged.
3. **`feat(cli): choose the app with --app, check every app with --all (ADR-0014)`.** `--app` plumbing for `init`, `preflight` and `doctor`.
   - The global options `--app` and `--all`, the table of section 3, messages 1 and 2, `app-flat-file` and `all-not-allowed`; the commands not built yet accept `--app` and refuse `--all`.
   - `preflight` and `doctor`: the app's default IPA, `== <app> ==`, the table, the exit code and the `--json` of sections 3 and 7.
   - `init --app` on a file of apps: adds or updates the entry in place with `yaml_edit` (section 5, without the migration; the new dependency, BSD-3-Clause, goes in here), `--credentials`, `--flavor` combined with `--configuration`, and `flavor` and `configuration` written in a flat file too. The rule of ADR-0013 that the two flags exclude each other is removed here.
   - Accepted when: goldens for messages 1 and 2 (text and `--json`, with and without redaction), the table and the `--all` object; the exit code test of section 6; a run with `CI` set prints no name, in text or in JSON; `init` adds an entry with a confirmation, needs `--force` to replace one, keeps `defaults`, the other entries and every comment (comments before, between and after entries survive a test run), and its diff shows only the changed lines.
4. **`feat(cli): migrate a one-app wincode.yaml to apps: with init --app (ADR-0014)`.**
   - The migration of section 5, `config-is-another-app` and `backup-exists`.
   - Accepted when: a test per step: the same app gives the proposal (golden diff); another app stops with nothing written; without a terminal and without `--yes` nothing is written; with `--yes` the backup is byte-identical and the new file gives every value of the old; an existing backup stops the run and is untouched; `--dry-run` writes neither file.

**As built: pull request 1 (schema and loader).** What the code does, and where this ADR left a choice:

- **Where.** `packages/wincode_cli/lib/src/config.dart`: `WincodeSettings` (the apps in file order, and whether the file is flat) and `WincodeConfig` (one app: now with `name`, `flavor`, `configuration`, `credentials` and `workflowInputs`), read by `loadSettings` and `parseSettings`. `loadConfig` and `parseConfig` still return one app, so no command changed; a file of several apps stops them with exit 64 (`not-implemented`). `lib/src/redact.dart`: `Redactor.hideName` matches whole words ignoring case, and every value is replaced in one pass, the longest first.
- **Flat files.** `test/goldens/config-flat.txt` records the loader's answers for 22 cases (21 flat files and a missing one) and was first written from the loader before this change. One line differs from that first version: the unknown-key message lists ten keys instead of six, because `flavor`, `configuration`, `workflow_inputs` and `credentials` are valid in a flat file too. Every other message and result is byte for byte the same.
- **Wired.** `preflight` passes its redactor to the loader. `init` is unchanged: it still writes a flat file, checks it with `parseConfig` without a redactor, and does not know the new keys. Nothing reads `credentials` or `WINCODE_KEYS_DIR` yet, and there is no `--app` or `--all`.
- **How the ADR was read:**
  1. The loader registers each name, ID and path with the redactor as soon as it has passed its checks, in file order, so an error prints placeholders for everything the loader has read before it. A name that fails its rules is never printed; a refused common word, Windows device name or placeholder shape is quoted, since it is not a brand.
  2. The reserved list is the fourteen words that section 4 names first plus the eleven names it adds (`defaults`, `init`, `doctor`, `preflight`, `status`, `team`, `credentials`, `output`, `workflow`, `entitlements`, `flavor`); it is the constant `reservedNames`. The same rules check a credentials reference, also in a flat file that writes one.
  3. A configuration that `Release-<flavor>` supplies is not in the file, so it is not registered; one the file writes is, as a whole value. A flavor or configuration on the reserved list, or shorter than 3 characters, is not registered. A flat file's flavor and configuration placeholders are `flavor-1` and `configuration-1`.
  4. A path is registered as resolved against the file, as absolute and normalised, and in both separator spellings, and as written when it holds a separator or a dot. A one-word relative folder such as `out` is therefore hidden only in its absolute form, because `out` as a substring would hide that word everywhere. The default output is registered too.
  5. The variable form of a reference (`TEAM_ONE`) is replaced as that exact upper-case string, and it wins a tie in length with the name.
  6. Output folders are compared ignoring case, the direction of separators and a trailing separator; nested folders are not compared.
  7. Messages that section 10 does not list are written in the same form: a key of an app next to `apps`, `defaults` without `apps`, `defaults` that is not a map, `apps` that lists no app, an app that holds no settings, a key that `defaults` may not hold, and each workflow-input rule. A secret-looking key at any level uses the secret message, which in a file of apps points at the credentials reference instead of the two variables.
  8. `package:yaml` does not expand merge keys, so `<<` reaches the loader as an ordinary key and is refused as unknown, as section 1 says.

**As built: pull request 2 (credentials resolution).** What the code does, and where this ADR left a choice:

- **Where.** `packages/wincode_cli/lib/src/credentials.dart`: `locateAscKeyFiles` (the App Store Connect half), `readAscKeyIds` (the Key ID from the file name and the Issuer ID from `issuer-id`, registered with the redactor), `resolveDistKey`, `keysRoot` and the variable names. `requireNoWorkTree` in `key_location.dart` is the strict git check. The legacy path moved there from `preflight.dart` with its code and messages unchanged: the existing `preflight` tests and goldens pass without an edit.
- **Wired.** `preflight` reads an app's key through `locateAscKeyFiles`: an app with `credentials` from its reference, a flat file without it from `WINCODE_ASC_KEY_DIR` as before. `doctor` without `--binary`, `--sdk` and `--reference` checks `settings` and `credentials` of the one app. Nothing calls `resolveDistKey` yet: `sign` is phase 3. There is still no `--app` or `--all`, and `init` is unchanged.
- **Messages 3 and 4 of section 10** are those of the ADR, word for word: a test reads them from this file. The variants are written in the same form: a variable of a reference that points into a working tree, the default root in one (a profile folder that is a repository), a reference folder that is itself a repository, a root or variable in OneDrive, a root that does not exist (with and without `WINCODE_KEYS_DIR`), and a missing user profile.
- **No `wsl.exe`.** No path of the resolution starts it, and the tests record every program that `preflight`, `doctor` and the resolution start: only `git`. `runWincode` gained a `run` parameter for that, as it has `connect` for the server.
- **How the ADR was read:**
  1. The default root is `.wincode/keys` in `USERPROFILE`, else in `HOME`, so that the tests and a run on another system have one. With neither and no `WINCODE_KEYS_DIR`, the credentials are missing, and the message says so.
  2. Order of the checks for a reference without a variable: the root exists, is not in OneDrive and not in a working tree; then the folder of the reference exists and is not itself in a working tree. The files inside are not asked about one by one, since the folder check covers them; `git check-ignore` is never asked. For a variable, the folder (for `dist.key`, the folder of the file) is checked.
  3. A `--dry-run` goes on without a token when the keys are not there, as it does without `WINCODE_ASC_KEY_DIR`, and says which; every other failure stops it.
  4. The Issuer ID and Key ID rules are `preflight`'s, with the source in the messages: `WINCODE_ASC_KEY_DIR` as before, the variable of the reference, or `the folder of the credentials <reference>`. The `PASS` line of the key-location check names the reference instead of the legacy variable. These names pass through the redactor, so `--redact` and CI print `credentials-1` and `WINCODE_ASC_KEY_DIR_CREDENTIALS_1`.
  5. The folders found are registered as secrets: the root as `<WINCODE_KEYS_DIR>`, the folder of a variable as `<keys folder>`, the distribution key's file as `<distribution key>`.
  6. `resolveDistKey` checks location only: whether `dist.key` exists, and what is in it, is for `sign`. For a flat file without `credentials` it returns null when `WINCODE_DIST_KEY` is not set. `WINCODE_DIST_KEY` and `WINCODE_DIST_KEY_<REF>` are not refused under `/mnt/`, as ADR-0013 now says.
  7. `doctor` without options has no usage error any more, as the Consequences below say; with only some of `--binary`, `--sdk` and `--reference`, the usage errors are as they were. A file of several apps fails its `settings` check with exit 64 until `--app` exists.

## Consequences

- **A white-label project keeps one file,** and winCode checks its apps against each other: no shared bundle ID, no shared output folder, one team per reference.
- **Keys follow the app, not the shell.** Moving between apps of different teams is `--app`, and no variable needs changing.
- **Nothing breaks.** A flat file and the two variables work as before. The visible changes for them: `init` now writes `flavor` and `configuration`, `--flavor` and `--configuration` may be given together, and `doctor` without `--binary` checks the setup instead of exiting 64.
- **`preflight`, `upload` and `status` never need WSL2,** and nothing key-related is written inside it. `sign` reads `dist.key` in place through `/mnt/<drive>`. The keys sit in the user's Windows profile, readable by the user's own programs, as the single key files were; ADR-0013's later step for encrypted keys (a private tmpfs copy) is unchanged.
- **Names are restricted:** an app or reference cannot be a common word or shorter than 3 characters, which keeps redaction from hiding ordinary words. Configured paths are hidden too. Brands that winCode does not know, in other paths and file names, are not hidden.
- **The keys root is held to a stricter rule** than ADR-0013's single files: no `.gitignore` exception. Two rules for keys until open question 5 is decided.
- **`init` gains a dependency,** `yaml_edit`, so that comments survive. Only the migration renders a file again, and its backup keeps the original.
- **To revisit:** the open questions of section 8, and `--all` for the commands that write, in a decision of its own.

## Alternatives considered

- **One file per app (`--config`)**, a list of apps instead of a map: section 1.
- **Key paths in `wincode.yaml`, variables per app, a credential store:** section 2.
- **A default app** (`default_app:`, `WINCODE_APP`, the first app): section 3.
- **`--all` for every command:** section 3, with what it would need.
- **Substring redaction of names, as for IDs:** an app called `app` would be replaced inside `application` and inside other placeholders; whole words in one pass avoid both (section 4).
- **Rendering the file again, or appending text, for `init`:** section 5; rendering is kept for new files and for the migration.
- **The keys root on the WSL2 disk:** section 2, option E.
- **`flavor` or `configuration`, one of the two:** `build` needs the flavor and `init` sometimes needs a configuration with another name (`Release-Alpha` for `alpha`), so an app that had to choose would lose one of them (section 1).
- **A per-app GitHub artifact name (`unsigned-ipa-<app>`):** it breaks workflows copied before, and it puts the app's name into the run's list of artifacts; the run's `request_id` already keeps apps apart (section 6).

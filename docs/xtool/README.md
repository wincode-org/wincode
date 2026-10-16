# xtool teardown (part 1, in progress)

How xtool works, recovered from its source, as input for winCode's plan. xtool is MIT open source, so this is a source-based analysis. No Apple software was decompiled.

- **Version analyzed:** xtool **1.22.2**, tag commit `65bf3cc` (2026-10-13). This is the version winCode runs.
- **Method:** read the code and trace each command through it.

## Module map

| Module | Swift lines | Role |
| --- | --- | --- |
| `xtool` | 18 | Entry point |
| `XToolSupport` | 3,083 | CLI commands; Darwin SDK builder (`SDKBuilder.swift`, 850 lines) |
| `PackLib` | 1,576 | Plans and builds the SwiftPM app (`Planner`, `Packer`, `BuildSettings`, `DarwinSDK`); Xcode project generation |
| `XKit` | 7,463 | Core: Apple account auth, Developer Services, provisioning, signing, device install |
| `DeveloperAPI` | 28,873 | Generated OpenAPI client for Apple's developer API |
| `XUtils`, `CXKit`, `XcodeProjects` | small | Utilities, C shims (mobileprovision parsing, version), Xcode project model |

**Commands** (`XToolSupport/XTool.swift`):
- Configuration: `setup` (= `auth` + `sdk`), `auth`, `sdk`.
- Development: `new`, `dev` (build, run, generate-xcode-project, build-server), `ds` (Developer Services: teams, devices, certificates, identifiers, profiles).
- Device: `devices`, `install`, `uninstall`, `launch`.

## Licences (what winCode may copy or ship)

- **xtool itself is MIT.** Copying its source is allowed; keep its copyright and licence notice.
- **Most of its 51 pinned packages are permissive** (MIT, Apache-2.0, BSD-2-Clause), including `zsign` (signing), `xtool-core` and `SwiftyMobileDevice`.
- **Copyleft parts:**
  - `xtool-org/xadi`: **LGPL-2.1**. Used by Apple ID password login.
  - `saagarjha/unxip`: **LGPL-3.0**. Extracts `Xcode.xip`.
  - The device libraries (libplist, libimobiledevice-glue, libusbmuxd, libtatsu, libimobiledevice): **LGPL-2.1**. They aren't vendored. `xtool-core` links them as system libraries; the Dockerfile builds them from source, and linuxdeploy bundles them as shared libraries into the AppImage.
- **What this means:** copying xtool's source copies no LGPL source. Shipping our *own* xtool binary would carry LGPL obligations: licence texts, source offer, relinkable shared libraries.

## Storage and secrets

- **Everything lives in `~/.config/xtool/`.** Key-value data is under `data/`, Anisette state under `Anisette/`. The live storage on every platform is plain files (`DirectoryStorage`); a Keychain backend exists but isn't the default.
- **The saved login (`XTLAuthToken`)** holds either the Apple ID session token or, in API-key mode, the **App Store Connect private key itself** (`AuthToken.swift`).
- **The signing certificate and its private key** (`SigningInfo`) are stored as a plist keyed by identity ID.
- **On the spike machine these files are mode 644,** in a 755 directory, with umask 0022. Only the 750 home directory keeps other local accounts out. winCode should keep secrets in Windows Credential Manager, as the plan says, and tighten file modes.

## Darwin SDK (`sdk`, `SDKBuilder.swift`)

1. **Read the input.** It accepts `Xcode.xip`, `Xcode.app` or a prebuilt `darwin.xtoolsdk`. A `.xip` is recognised by its `xar!` magic bytes.
2. **Download two helpers from GitHub releases:**
   - the Linux toolset `xtool-org/darwin-tools-linux-llvm` v1.1.0: `ld64.lld`, `llvm-lib` (renamed from `libtool`) and `dsymutil`;
   - `OpenAppleMacrosServer` v1.3.0, used as the Swift macro plugin server.
   Downloads are checked **only for HTTP 200, with no checksum or signature verification.** winCode should pin and verify them.
3. **Wrap the linker.** `ld64.lld` is replaced by a shell trampoline: lld can't do relocatable `-r` links, so those calls become a static archive built with `llvm-lib`.
4. **Extract Xcode.** unxip streams the xip. A path allowlist keeps:
   - the toolchain's `usr/lib/{swift,swift_static,clang}`;
   - for each of iPhoneOS, MacOSX and iPhoneSimulator: `Info.plist`, `Developer/SDKs`, `Developer/Library/{Frameworks,PrivateFrameworks}` and `Developer/usr/lib`.
   Prebuilt Swift modules are dropped. The "normal" flavor keeps a copy of `Xcode.app` and hard-links files so the SDK can update in place; "slim" copies files and can't update.
5. **Patch for Linux:**
   - Platform `Info.plist`: lld as the linker; `CODESIGN=true`, because signing happens after the build; Swift and clang resource directories.
   - Testing frameworks are symlinked into the SDKs.
   - Macro plugins are routed to OpenAppleMacros through stub `.so` files.
   - The host clang `include` directory is copied in.
6. **Write the SwiftPM bundle:**
   - `swift-sdk.json` with five triples (iOS device, iOS simulator arm64/x86_64, macOS arm64/x86_64);
   - `toolset.json` and `toolset-swb.json`;
   - `darwin-sdk-version.txt` (`epoch=3,darwinTools=1.1.0,oam=1.3.0`).
   It installs to `~/.swiftpm/swift-sdks/darwin.artifactbundle`, or `$XDG_CONFIG_HOME/swiftpm/...`. A version mismatch triggers an update (normal flavor) or a reinstall.

## Build and packaging (`dev build`, `PackLib`)

1. **Plan** (`Planner`):
   - `swift package show-dependencies` and `describe` build the package graph.
   - The app is the single library product, or the one named in `xtool.yml`.
   - Each target's binary targets, resource bundles and dynamic-library dependencies become **resources** to embed.
   - `Info.plist` is generated (bundle ID from `bundleID` or `orgID.product`, `UILaunchScreen`, orientations, device family), then merged with `infoPath`.
   - App extensions come from `xtool.yml` `extensions`.
2. **Build** (`Packer`): it writes a hidden builder package, `xtool/.xtool-tmp`, with one executable target per product. Each target links the app library, with rpath `@executable_path/Frameworks`. It then runs `swift build` with `--swift-sdk` (SwiftPM) or `--triple` plus `--toolset` (SwiftBuild, the default on Swift 6.4).
3. **Pack:**
   - Copy the executable.
   - Copy dynamic binary-target frameworks to `Frameworks/<name>.framework`. Static archives are skipped.
   - Copy `lib<name>.dylib` products to `Frameworks/`.
   - Copy resource bundles, and `xtool.yml` `resources` to the app root.
   - Write `Info.plist`, adding `UIRequiredDeviceCapabilities`, `LSRequiresIPhoneOS` and `CFBundleSupportedPlatforms`.
   - The result is `xtool/<Product>.app`, unsigned.
4. **Consequence for winCode:** frameworks that SwiftPM links are embedded automatically. `App.framework` can't be linked (no exports trie), so winCode embeds it after the build (spike B).

## Provisioning, signing, install (summary so far)

- **`install` and `dev run`** both go through `IntegratedInstaller`:
  1. unpack (`.ipa` or `.app`) into `Payload/`
  2. lockdown handshake with the device
  3. provision and sign in place (`AutoSigner`)
  4. zip
  5. upload and install (`AppInstaller`)
- **Provisioning** (`DeveloperServicesProvisioningOperation`):
  - Register the device, then fetch or create a development certificate. If certificates must be revoked, xtool prompts "Continue?"; with no input, the answer is no.
  - Register App IDs, then fetch profiles.
  - Only the app and its `PlugIns/` or `Extensions/*.appex` are provisioned, and their bundle IDs are rewritten to `XTL-<account id>.<bundle id>`.
  - Frameworks keep their own bundle IDs.
- **Signing:** xtool's fork of zsign (`Zupersign`) with the provisioned entitlements; `get-task-allow` is set for development certificates.
- **Device link:** libimobiledevice through `SwiftyMobileDevice`. `USBMUXD_SOCKET_ADDRESS` points it at a TCP usbmux service, such as Apple's Windows service (ADR-0005).
- **No launch on Linux:** mounting the developer disk image is not implemented there (`DDIMounter`).
- **Authentication modes:**
  - App Store Connect API key: official public API, JWT. winCode's preferred path.
  - Apple ID password: uses Apple's private sign-in service and the LGPL `xadi` module. It breaks when Apple changes the service (`-80045`, fixed in 1.22.2). It is documented here at architecture level only.

## Still to analyze (next session)

1. Developer Services client internals: the two API modes, paging, errors, team handling.
2. `SignerImpl` and the zsign interface in detail.
3. Installation internals: `Connection`, `ConnectionManager`, `IPAUploader`, `IPAInstaller`, `HeartbeatHandler`, `ProfileManager`, `Debugger`.
4. The HTTP client: trust roots, proxy and debug environment variables.
5. `NewCommand` templates and `XcodePacker`.
6. The winCode plan section: what winCode reuses through xtool releases, what it owns, and whether to vendor xtool's source into `third_party/xtool` under ADR-0006.

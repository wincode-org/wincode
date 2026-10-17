# winCode plan from the xtool teardown

What the teardown (`README.md`) means for winCode. It feeds phase 1 (issue #7).

## 1. How winCode uses xtool in v1

winCode runs xtool's official release (1.22.2 or later) as a separate process inside WSL2 (ADR-0001, ADR-0006). The contract:

| Step | xtool command | winCode provides | Notes |
| --- | --- | --- | --- |
| Darwin SDK | `xtool sdk install <path to Xcode.xip>` | The path to the user's own `Xcode.xip`, which they download from Apple | About 8 GB. xtool downloads its toolset during this step |
| Login | `xtool auth login -m key`, answering key ID, issuer ID and key path on stdin | The App Store Connect API key, from Windows Credential Manager | Preferred path (official API). Apple ID login (`-m password`) is for free accounts only and can break when Apple changes its service |
| Build the runner | `xtool dev build` in the generated runner package | The translated SwiftPM package, with `Flutter.xcframework` as a binary target | Unsigned `.app`. Use `-c release` for anything shipped |
| Embed Dart | — (winCode) | Copies `App.framework` to `Frameworks/App.framework` | It can't be linked (no exports trie) |
| Provision, sign, install | `xtool install --usb <CounterRunner.app>` | `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015` (Apple's Windows service, ADR-0005) | Registers the device, manages the certificate, App ID and profile, signs, uploads and installs |
| Devices | `xtool devices --usb` | Same environment | For `wincode doctor` and device selection |

**Process rules for the wrapper** (from the tested behaviour):
- Pass every input as a flag, or as lines on a stdin pipe.
- An unanswered prompt fails at once with exit code 1. Map those messages ("Operation unsupported", "I/O on closed channel") to clear winCode errors.
- Never answer "yes" to certificate revocation for the user. Show xtool's list and ask in winCode's own UI.
- Run xtool with a winCode-owned `HOME` (or `XDG_CONFIG_HOME`), so winCode controls where its secrets go (section 2).
- Put a timeout on every call. A device that never answers leaves xtool waiting ("Waiting for device to be connected...").

## 2. What winCode must handle around xtool

1. **Secrets at rest.**
   - xtool writes the login token, which in key mode **contains the `.p8` key**, and the signing private key as plain files, mode 644.
   - winCode should run xtool with a `HOME` under a directory with mode 700, make the files 600 after each run, and keep the master copy of the API key in Windows Credential Manager (`docs/PLAN.md`, "Signing").
   - Logging out in winCode must also clear xtool's copy.
2. **Unverified downloads.** The toolset and OpenAppleMacros are fetched without checksums. winCode should verify the installed files against pinned hashes after `sdk install`, and refuse to build if they differ.
3. **Large apps.** xtool reads the whole `.ipa` into memory before uploading. Test a large Flutter app (for example 300 MB) before G1.
4. **Profile churn.**
   - Every install deletes and recreates the App ID's profile with every iOS device on the team.
   - That's harmless for development, but winCode should show which team and devices are affected.
   - Free teams also have limits on App IDs and certificates.
5. **Free-team certificate revocation.** On a free team, a new certificate can require revoking old ones, including ones that other tools use. `wincode setup` must explain this before it happens.
6. **First launch on the device:** the user trusts the developer profile in Settings and turns on Developer Mode. `wincode run` should detect "untrusted" and guide the user.
7. **Release builds:** the debug runner embeds build-machine rpaths; release builds must not (spike B).
8. **Extensions:** `Signer.sign` passes only the app's entitlements to zsign. Test an app extension before winCode supports them.

## 3. Launch: the open question

`xtool launch` uses the device's lockdown `debugserver` service. On iOS 17 and later that normally needs a mounted developer disk image, and xtool's disk-image mounting is unused and stubbed on Linux.

**First test** (needs the iPhone connected):

```
USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015 xtool launch --usb <installed bundle id>
```

**The disk image itself:**
- The SDK's `Xcode.app` copy holds only **legacy** developer disk images (`iPhoneOS.platform/DeviceSupport` 15.0–16.4). The **personalized** image that iOS 17+ needs isn't there.
- If the `.xip` carries one, it would be under `Contents/Resources`, which xtool's cleanup deletes; this is not yet checked.
- Before choosing a launch path, check the user's own `Xcode.xip` for it.
- winCode must never download Apple's disk images from third-party mirrors (`docs/PLAN.md`, legal section).

- **If it works:** `wincode run` uses it.
- **If it fails:** the candidate is pymobiledevice3 on Windows through the same Apple service. It mounts the personalized developer disk image and launches over the iOS 17 tunnel. It's GPL-3.0, so it must run as a separate process the user installs (ADR-0002). This path is also the start of phase 3 (debugging and hot reload).

## 4. What winCode owns

Not in xtool, and built in winCode (ADR-0006):

- Flutter project translator: `ios/Runner` → runner SwiftPM package.
- `gen_snapshot` for iOS and `App.framework` (ADR-0004).
- Windows setup and the device link (ADR-0005).
- Launch, logs, debugging and hot reload (phase 3).
- Asset catalog compiler (`Assets.car`) and App Store upload (phase 4). winCode can build its Dart App Store Connect client (`packages/wincode_asc`) from Apple's published OpenAPI schema, as xtool does in Swift.

## 5. Copying xtool's source into winCode

- **Legal:** yes. xtool is MIT.
- **What to copy:** the 1.22.2 tree (`65bf3cc`) into `third_party/xtool/`, with its `LICENSE.md` unchanged and a `README.md` stating the source, version and any local changes.
- **What to leave out:** the three tutorial screenshots (8.6 MB). The scan found no keys, certificates or profiles in the tree.
- **Dependencies stay external.** SwiftPM fetches them, so no LGPL source is copied.
- **When the LGPL parts matter:** only when winCode builds and **ships its own xtool binary**. Then:
  - `xadi` (LGPL-2.1), `unxip` (LGPL-3.0) and the libimobiledevice family (LGPL-2.1) need their licence texts;
  - a source offer;
  - shared, replaceable libraries, which the AppImage already uses.
- **Recommendation:** copy the source now for reference and patching, but keep running the official release binary in v1. Switch to building our own binary only when winCode needs a patch upstream won't take, for example launch on Linux, streaming upload, or secret storage. Record each local patch in `third_party/xtool/README.md`, so new upstream releases can still be merged.

## 6. Next steps

1. Test `xtool launch` on the iPhone (section 3) and record the result.
2. Copy xtool's source to `third_party/xtool/` (section 5) in its own pull request.
3. Add to issue #7:
   - wrapper rules (section 1)
   - secret hardening (2.1)
   - download verification (2.2)
   - a large-app install test (2.3)
   - the launch path (section 3)

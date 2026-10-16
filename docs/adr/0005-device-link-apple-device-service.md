# 0005. Reach the iPhone through Apple's Windows device service

- Status: Accepted
- Date: 2026-10-16

## Context

The toolchain runs in WSL2 (ADR-0001), but the iPhone is plugged into Windows. Spike B (`docs/spikes/spike-b-device.md`) tried two ways for xtool in WSL to reach it.

**usbipd-win, which forwards the USB device into WSL.**
- Device info and provisioning worked.
- The install upload stalled. usbmuxd logged `device unconfigured`, and the iPhone reported `message was too large (65536 bytes, max = 65535)`: USB/IP merges USB packets.
- References: xtool-org/xtool#19 and #341, dorssel/usbipd-win#959.

**Apple's device service on Windows, from the Apple Devices app.**
- It speaks the usbmux protocol on `127.0.0.1:27015`.
- WSL reaches it in mirrored networking mode, with `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015`.
- Provisioning, signing and install completed in 15 s, and the device log streamed over the same link.

## Decision

- **winCode reaches iPhones only through Apple's Windows device service.**
  - The user installs Apple's "Apple Devices" app from the Microsoft Store: `winget install --id 9NP83LWLPZ9K --source msstore`.
  - winCode never ships Apple software.
- **WSL runs in mirrored networking mode**, so tools in WSL reach the service at `127.0.0.1:27015`. winCode sets `USBMUXD_SOCKET_ADDRESS` for the tools it runs there (xtool, libimobiledevice).
- **`wincode setup` checks these, and fixes them with the user's consent:**
  - Apple Devices is installed.
  - The service is listening. In the Store app it is a startup task, so it may need starting, as `spikes/b-device/start-apple-mobile-device.ps1` does.
  - `.wslconfig` has `networkingMode=mirrored`. Back up the file first; the change needs one WSL restart.
  - The iPhone is not attached to WSL through usbipd.
  - The iPhone trusts this computer.
- **usbipd is not supported** for device work.

## Consequences

- No admin rights and no firewall changes are needed.
- **winCode depends on Apple software that the user installs, and Apple can change it.** The Store app runs its device stack as a startup task, not a Windows service. That is observed behaviour, not documented by Apple.
- **Mirrored networking applies to every WSL distro on the machine.** Compatibility with Docker Desktop and VPN clients is not tested yet. The NAT alternative below is the fallback.
- **Windows-side tools can use the same service**, for example pymobiledevice3 for launch and debugging in phase 3. Phase 3 does not need a second device path.
- **Launching an app from WSL is still not possible.** xtool cannot mount the developer disk image on Linux, so until winCode has a launch path the user opens the app by hand.
- iTunes provides the same service and should work the same way. Not tested.

## Alternatives considered

- **usbipd-win:** fails on bulk transfers (see Context).
- **NAT networking with `netsh interface portproxy` plus a firewall rule** (xtool-org/xtool#19): works according to reports, but needs admin rights, and WSL's adapter IP can change after a reboot.
- **A reverse SSH tunnel from Windows into WSL:** no admin rights, but more moving parts.
- **Install from Windows with pymobiledevice3 while WSL only builds and signs:** workable, but it adds a GPL tool to the release loop. Reconsider for phase 3.

#!/usr/bin/env python3
"""Spike C, C1: the store bundle, unsigned, from spike D's counter bundle.

  c1_bundle.py <spike D .app> <reference folder> <out dir>

<reference folder> holds the macOS reference run's artifacts (run 39513689791), kept outside the repo:
  icon-sample/compiled/          Xcode's Assets.car, icon PNGs and partial Info.plist (actool on the runner)
  xcode-counter-app/Runner.app   Xcode's counter app: its compiled LaunchScreen.storyboardc, and the bundle that
                                 ipa-diff compares with
The bundle ID, version and build number come from config.json in WINCODE_SPIKE_C_DIR, never from the repo.
Writes <out>/<executable>.app, <out>/c1-unsigned.ipa and <out>/ipa-diff-c1.txt, and prints the diff's counts.
"""
import plistlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

from asc_preflight import REPO, spike_config

# Apple's privacy manifest keys, all empty: the runner calls no required-reason API, collects no data and does no
# tracking. Flutter.framework ships its own manifest for the engine.
PRIVACY = {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [],
           "NSPrivacyAccessedAPITypes": []}


def build(spike_d_app, reference, out):
    _, config = spike_config()
    icons, xcode_app = reference / "icon-sample/compiled", reference / "xcode-counter-app/Runner.app"
    info = plistlib.loads((spike_d_app / "Info.plist").read_bytes())
    app = out / f"{info['CFBundleExecutable']}.app"
    out.mkdir(parents=True, exist_ok=True)
    if app.exists():
        shutil.rmtree(app)
    shutil.copytree(spike_d_app, app, symlinks=True)

    for name in ("Assets.car", "AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png"):
        shutil.copy2(icons / name, app / name)
    # The runner is a SwiftUI app: it needs no Main.storyboardc and no scene configuration.
    shutil.copytree(xcode_app / "Base.lproj/LaunchScreen.storyboardc", app / "Base.lproj/LaunchScreen.storyboardc")
    (app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(PRIVACY))

    info.update(plistlib.loads((icons / "partial-Info.plist").read_bytes()))  # CFBundleIcons, CFBundleIcons~ipad
    info.pop("UILaunchScreen", None)
    info.update({
        "CFBundleIdentifier": config["bundle_id"],
        "CFBundleShortVersionString": config["version"],
        "CFBundleVersion": config["build"],
        "UILaunchStoryboardName": "LaunchScreen",
        "ITSAppUsesNonExemptEncryption": False,  # the counter app uses no encryption
    })
    if int(info["MinimumOSVersion"].split(".")[0]) < 13:  # uploads need iOS 13 or later since 2026-09-09
        sys.exit(f"MinimumOSVersion {info['MinimumOSVersion']} is below 13")
    (app / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))

    ipa = out / "c1-unsigned.ipa"
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(app.rglob("*")):
            z.write(f, Path("Payload") / f.relative_to(out))
    diff = subprocess.run([sys.executable, REPO / "tools/ipa-diff", app, xcode_app], capture_output=True, text=True)
    (out / "ipa-diff-c1.txt").write_text(diff.stdout + diff.stderr)
    counts, section = {}, None
    for line in diff.stdout.splitlines():
        if line.startswith("== "):
            section = line[3:].split(" ")[0]
            counts[section] = 0
        elif section and line.startswith("  ") and not line.startswith("  --") and "no differences" not in line:
            counts[section] += 1
    print(f"{app}\n{ipa}\nipa-diff: " + ", ".join(f"{k} {n}" for k, n in counts.items()))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    build(*(Path(a).resolve() for a in sys.argv[1:]))

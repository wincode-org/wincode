#!/usr/bin/env python3
"""Spike D: the bundle edits that bring a Windows-built runner .app closer to Xcode's output.

  bundle_fix.py rpaths <mach-o> <keep>...                 drop every LC_RPATH not in <keep>
  bundle_fix.py plist <app> <app Info.plist> <iPhoneOS.sdk> <pubspec.yaml>
  bundle_fix.py shaders <app> <flutter-root>              recompile flutter_assets/shaders for iOS

Edits are made before signing; xtool signs the result. Mach-O layout as in mach-o/loader.h.
"""
import json
import plistlib
import re
import struct
import subprocess
import sys
from pathlib import Path

LC_RPATH = 0x8000001C


def rpaths(binary, keep):
    """Remove LC_RPATH commands whose path is not in keep: shift the later commands up and zero the tail."""
    data = bytearray(Path(binary).read_bytes())
    magic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    assert magic == 0xFEEDFACF, f"{binary}: not a 64-bit Mach-O"
    kept, removed, offset = [], [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        command = bytes(data[offset:offset + size])
        if cmd == LC_RPATH:
            name_offset = struct.unpack_from("<I", command, 8)[0]
            path = command[name_offset:].split(b"\0", 1)[0].decode()
            if path not in keep:
                removed.append(path)
                offset += size
                continue
        kept.append(command)
        offset += size
    body = b"".join(kept)
    data[32:32 + sizeofcmds] = body + b"\0" * (sizeofcmds - len(body))
    struct.pack_into("<II", data, 16, len(kept), len(body))
    Path(binary).write_bytes(data)
    for path in removed:
        print(f"removed rpath {path}")


def plist(app, app_plist, sdk, pubspec):
    """Merge the app's own Info.plist into the runner's, then add the SDK keys Xcode writes."""
    app = Path(app)
    built = plistlib.loads((app / "Info.plist").read_bytes())
    name, number = re.search(r"^version:\s*([^+\s]+)\+(\S+)", Path(pubspec).read_text(), re.M).groups()
    subs = {
        "DEVELOPMENT_LANGUAGE": "en",
        "EXECUTABLE_NAME": built["CFBundleExecutable"],
        "PRODUCT_BUNDLE_IDENTIFIER": built["CFBundleIdentifier"],  # the runner's App ID, not a new one
        "PRODUCT_MODULE_NAME": built["CFBundleExecutable"],
        "FLUTTER_BUILD_NAME": name,
        "FLUTTER_BUILD_NUMBER": number,
    }

    def expand(value):
        if isinstance(value, str):
            def var(m):
                if m.group(1) not in subs:
                    raise SystemExit(f"unknown Info.plist variable $({m.group(1)})")
                return subs[m.group(1)]
            return re.sub(r"\$\(([A-Za-z0-9_]+)\)", var, value)
        if isinstance(value, list):
            return [expand(v) for v in value]
        if isinstance(value, dict):
            return {k: expand(v) for k, v in value.items()}
        return value

    own = expand(plistlib.loads(Path(app_plist).read_bytes()))
    # The runner ships no storyboards and no SceneDelegate class (accepted for now): drop what points at them.
    for key in ("UIMainStoryboardFile", "UILaunchStoryboardName"):
        own.pop(key, None)
    own.get("UIApplicationSceneManifest", {}).pop("UISceneConfigurations", None)
    merged = {**built, **own}

    sdk = Path(sdk)
    settings = json.loads((sdk / "SDKSettings.json").read_text())
    system = plistlib.loads((sdk / "System/Library/CoreServices/SystemVersion.plist").read_bytes())
    platform = plistlib.loads((sdk.parents[2] / "Info.plist").read_bytes())  # iPhoneOS.platform/Info.plist
    merged.update({
        "DTSDKName": settings["CanonicalName"],
        "DTSDKBuild": system["ProductBuildVersion"],
        "DTPlatformName": settings["DefaultProperties"]["PLATFORM_NAME"],
        "DTPlatformVersion": platform["AdditionalInfo"]["DTPlatformVersion"],
        # xtool's SDK keeps no platform version.plist; the platform build is the SDK's build.
        "DTPlatformBuild": system["ProductBuildVersion"],
    })
    (app / "Info.plist").write_bytes(plistlib.dumps(merged, fmt=plistlib.FMT_BINARY))
    for key in sorted(set(merged) - set(built)):
        print(f"added {key} = {merged[key]!r}")


def shaders(app, flutter_root):
    """`flutter build bundle` compiles shaders for Android whatever the target (CopyFlutterBundle), so
    recompile each one with flutter_tools' iOS impellerc arguments."""
    impellerc = Path(flutter_root) / "bin/cache/artifacts/engine/linux-x64/impellerc"
    sources = {p.name: p for p in sorted((Path(flutter_root) / "packages/flutter/lib/src").rglob("*.frag"))}
    for out in sorted((Path(app) / "Frameworks/App.framework/flutter_assets/shaders").glob("*.frag")):
        src = sources[out.name]
        subprocess.run([impellerc, "--runtime-stage-metal", "--iplr", f"--sl={out}", f"--spirv={out}.spirv",
                        f"--input={src}", "--input-type=frag", f"--include={src.parent}",
                        f"--include={impellerc.parent / 'shader_lib'}"], check=True, capture_output=True)
        Path(f"{out}.spirv").unlink()
        print(f"recompiled {out.name} for iOS from {src.relative_to(flutter_root)}")


if __name__ == "__main__":
    command, args = sys.argv[1], sys.argv[2:]
    {"rpaths": lambda: rpaths(args[0], set(args[1:])),
     "plist": lambda: plist(*args),
     "shaders": lambda: shaders(*args)}[command]()

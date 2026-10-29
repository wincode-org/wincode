#!/usr/bin/env python3
"""Spike C: sign the C1 bundle for the App Store with zsign (ADR-0009).

  sign.py [--dry-run] [--entitlements <app .entitlements>] <unsigned .app> <out .ipa>
  sign.py --self-test        offline: check the rule that compares entitlements with the profile's

Reads from the folder WINCODE_SPIKE_C_DIR names: the Apple Distribution certificate (one .cer) and the App Store
profile (one .mobileprovision), both downloaded from the developer portal, and config.json. dist.key (dist-key.sh)
stays in WSL: WINCODE_DIST_KEY names it, and a path under /mnt/ (a Windows drive) is refused.

The app is signed with a minimal set of entitlements built at run time from the profile's team ID and the config's
bundle ID: application-identifier, com.apple.developer.team-identifier, get-task-allow false and
keychain-access-groups with the app's own group. This set is not checked against what Xcode signs. Each key and
value must be allowed by the profile, or the script stops. With --entitlements, the keys of the app's own
.entitlements file (Sign in with Apple, for one) are added to the four and checked the same way; the four keep their
values. zsign gives these to the main executable and every
framework none (its archo.cpp signs only MH_EXECUTE files with entitlements); the script then reads every signature
back and checks exactly that, and that the IPA holds only Payload/.
--dry-run checks the inputs that are there, then prints the zsign command instead of running it. IDs are masked in
everything it prints. ZSIGN overrides the zsign path (default: the one build-zsign.sh makes under ~/spikes/spike-c).
"""
import argparse
import datetime
import importlib.machinery
import importlib.util
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import serialization

from asc_preflight import MASK, REPO, masked, spike_config

ZSIGN = os.environ.get("ZSIGN", str(Path.home() / "spikes/spike-c/zsign-f6158be9e62a5ce2a53d72b1a6d880880da956c8/bin/zsign"))
LIMIT = 1 << 30  # bytes; zsign once zipped its own output in a loop
loader = importlib.machinery.SourceFileLoader("ipa_diff", str(REPO / "tools/ipa-diff"))
ipa_diff = importlib.util.module_from_spec(importlib.util.spec_from_loader("ipa_diff", loader))
loader.exec_module(ipa_diff)


def one(folder, pattern):
    found = sorted(folder.glob(pattern))
    return found[0] if len(found) == 1 else None


def permits(allowed, value):
    """A profile's entitlement allows a value equal to it, a string its trailing * wildcard matches, or a list
    whose every item one of its own items allows."""
    if isinstance(value, list):
        options = allowed if isinstance(allowed, list) else [allowed]
        return all(any(permits(a, v) for a in options) for v in value)
    if isinstance(allowed, str) and isinstance(value, str) and allowed.endswith("*"):
        return value.startswith(allowed[:-1])
    return type(allowed) is type(value) and allowed == value


def minimal_entitlements(profile, bundle_id, extra=None):
    """(entitlements, problems): the minimal set for the app, each key and value checked against the profile.

    extra: the app's own entitlements (its .entitlements file). Its keys are added to the four of the minimal set
    (ADR-0011 rule 6) and checked the same way; the four keep the values built here."""
    team = profile["TeamIdentifier"][0]
    app_id = f"{team}.{bundle_id}"
    want = {**(extra or {}), "application-identifier": app_id, "com.apple.developer.team-identifier": team,
            "get-task-allow": False, "keychain-access-groups": [app_id]}
    allowed = profile["Entitlements"]
    problems = [f"the profile does not allow {key}" if key not in allowed else f"the profile does not allow this {key}"
                for key, value in want.items() if key not in allowed or not permits(allowed[key], value)]
    return want, problems


def show(entitlements):
    return masked(", ".join(f"{k}={v}" for k, v in sorted(entitlements.items()))) or "none"


def check_inputs(folder, config, app, extra=None):
    """The key, certificate and profile, checked against each other and the bundle. Returns (inputs, problems)."""
    now = datetime.datetime.now(datetime.timezone.utc)
    if not os.environ.get("WINCODE_DIST_KEY"):
        sys.exit("set WINCODE_DIST_KEY to dist.key in WSL (docs/spikes/spike-c-store-acceptance.md)")
    key, cert, profile = Path(os.environ["WINCODE_DIST_KEY"]), one(folder, "*.cer"), one(folder, "*.mobileprovision")
    problems, entitlements, der = [], None, None
    bundle_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
    if bundle_id != config["bundle_id"]:
        problems.append("the bundle's CFBundleIdentifier is not the bundle ID in config.json")
    if str(key.resolve()).startswith("/mnt/"):
        sys.exit("dist.key must stay in WSL: WINCODE_DIST_KEY points to a Windows drive")
    if not key.is_file():
        problems.append("dist.key is missing (dist-key.sh, WINCODE_DIST_KEY)")
    if cert is None:
        problems.append("no single .cer: download the Apple Distribution certificate into WINCODE_SPIKE_C_DIR")
    else:
        data = cert.read_bytes()
        certificate = (x509.load_pem_x509_certificate if data.startswith(b"-----") else x509.load_der_x509_certificate)(data)
        der = certificate.public_bytes(serialization.Encoding.DER)
        expires = certificate.not_valid_after.replace(tzinfo=datetime.timezone.utc)
        name = certificate.subject.get_attributes_for_oid(x509.NameOID.COMMON_NAME)[0].value
        print(f"certificate: {name.split(':')[0]}, valid until {expires:%Y-%m-%d}")
        if not name.startswith(("Apple Distribution:", "iPhone Distribution:")):
            problems.append("the certificate is not a distribution certificate")
        if expires < now:
            problems.append("the certificate has expired")
        if key.is_file():
            ours = serialization.load_pem_private_key(key.read_bytes(), password=None).public_key()
            if ours.public_numbers() != certificate.public_key().public_numbers():
                problems.append("the certificate is not for dist.key")
    if profile is None:
        problems.append("no single .mobileprovision: download the App Store profile into WINCODE_SPIKE_C_DIR")
    else:
        # The profile is a CMS-signed plist; only its content is read here, Apple's signature is not checked.
        content = subprocess.run(["openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", profile],
                                 capture_output=True, check=True).stdout
        p = plistlib.loads(content)
        MASK[p["TeamIdentifier"][0]] = "<team ID>"
        print(f"profile: valid until {p['ExpirationDate']:%Y-%m-%d}, allows: {', '.join(sorted(p['Entitlements']))}")
        if p["Entitlements"].get("application-identifier") != f"{p['TeamIdentifier'][0]}.{config['bundle_id']}":
            problems.append("the profile is not for the bundle ID in config.json")
        if "ProvisionedDevices" in p or p.get("ProvisionsAllDevices") or p["Entitlements"].get("get-task-allow"):
            problems.append("the profile is not an App Store profile")
        if p["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) < now:
            problems.append("the profile has expired")
        if der is not None and der not in p["DeveloperCertificates"]:
            problems.append("the profile does not include this certificate")
        entitlements, refused = minimal_entitlements(p, config["bundle_id"], extra)
        problems += refused
        print(f"app entitlements: {show(entitlements)}")
    return (key, cert, profile, entitlements), problems


def check_signed(ipa, entitlements):
    """Every Mach-O is signed; the main executable carries exactly our entitlements, the rest none; only Payload/."""
    with zipfile.ZipFile(ipa) as z:
        outside = [n for n in z.namelist() if not n.startswith("Payload/")]
    assert not outside, f"the IPA holds {len(outside)} entries outside Payload/"
    with tempfile.TemporaryDirectory() as tmp:
        executable, files = ipa_diff.load(ipa_diff.open_bundle(ipa, tmp))
    assert "embedded.mobileprovision" in files, "no embedded.mobileprovision"
    for path, data in files.items():
        info = ipa_diff.macho(data)
        if info is None:
            continue
        got = ipa_diff.entitlements(info["signature"])
        assert got is not None, f"{path} is not signed"
        want = entitlements if path == "<executable>" else {}
        assert got == want, f"{path}: entitlements {sorted(got)} instead of {sorted(want)}"
        print(f"signed: {path}, entitlements: {show(got)}")
    print("the IPA holds only Payload/")


def size(*paths):
    return sum(f.stat().st_size for p in paths if p.exists() for f in ([p] if p.is_file() else p.rglob("*"))
               if f.is_file() and not f.is_symlink())


def main(app, ipa, dry_run, app_entitlements=None):
    folder, config = spike_config()
    if app == ipa.parent or app in ipa.parents:
        sys.exit("the IPA must go outside the .app")
    extra = plistlib.loads(app_entitlements.read_bytes()) if app_entitlements else None
    (key, cert, profile, entitlements), problems = check_inputs(folder, config, app, extra)
    command = [ZSIGN, "-k", key, "-c", cert or "<certificate .cer>", "-m", profile or "<profile .mobileprovision>",
               "-e", "<entitlements.plist: the app entitlements above>", "-o", ipa, "-z", "9", "<Payload/ copy of the .app>"]
    if dry_run:
        print(masked("would run: " + " ".join(map(str, command))))
        print("\n".join(f"waiting: {p}" for p in problems) or "inputs OK")
        return
    if problems:
        sys.exit("\n".join(problems))
    # zsign signs a folder in place, so it gets a copy. It zips the whole folder that holds Payload/<app>, so that
    # folder holds nothing else, and its cache goes to the working directory beside it.
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        copy = tmp / "bundle/Payload" / app.name
        shutil.copytree(app, copy, symlinks=True)
        (tmp / "entitlements.plist").write_bytes(plistlib.dumps(entitlements))
        command[command.index("-e") + 1], command[-1] = tmp / "entitlements.plist", copy
        ipa.unlink(missing_ok=True)
        zsign = subprocess.Popen(list(map(str, command)), cwd=tmp, stdout=subprocess.DEVNULL)
        while zsign.poll() is None:
            if size(tmp, ipa) > LIMIT:
                zsign.kill()
                zsign.wait()
                ipa.unlink(missing_ok=True)
                sys.exit("stopped zsign: its files passed 1 GB")
            time.sleep(0.5)
        if zsign.returncode:
            sys.exit(f"zsign failed with exit code {zsign.returncode}")
    check_signed(ipa, entitlements)
    print(f"signed: {ipa}, {ipa.stat().st_size} bytes")


def self_test():
    profile = {"TeamIdentifier": ["TEAM000000"],
               "Entitlements": {"application-identifier": "TEAM000000.org.example.app", "get-task-allow": False,
                                "com.apple.developer.team-identifier": "TEAM000000", "beta-reports-active": True,
                                "keychain-access-groups": ["TEAM000000.*", "com.apple.token"]}}
    want, problems = minimal_entitlements(profile, "org.example.app")
    assert not problems and want == {"application-identifier": "TEAM000000.org.example.app",
                                     "com.apple.developer.team-identifier": "TEAM000000", "get-task-allow": False,
                                     "keychain-access-groups": ["TEAM000000.org.example.app"]}, problems
    assert not permits("TEAM000000.*", "OTHER00000.org.example.app")
    assert not permits(["TEAM000000.org.example.app"], ["TEAM000000.org.example.other"])
    assert not permits(False, 0) and not permits(True, False) and not permits("a", "ab")
    for change in ({"get-task-allow": True}, {"keychain-access-groups": ["OTHER00000.*"]},
                   {"application-identifier": "TEAM000000.org.example.other"}):
        assert minimal_entitlements({**profile, "Entitlements": {**profile["Entitlements"], **change}},
                                    "org.example.app")[1], change
    # The app's own entitlements are signed too, when the profile allows them (Sign in with Apple), and never replace the four.
    siwa = {"com.apple.developer.applesignin": ["Default"]}
    allowing = {**profile, "Entitlements": {**profile["Entitlements"], **siwa}}
    want, problems = minimal_entitlements(allowing, "org.example.app", {**siwa, "get-task-allow": True})
    assert not problems and want["com.apple.developer.applesignin"] == ["Default"] and want["get-task-allow"] is False, problems
    assert minimal_entitlements(profile, "org.example.app", siwa)[1] == ["the profile does not allow com.apple.developer.applesignin"]
    del profile["Entitlements"]["keychain-access-groups"]
    assert minimal_entitlements(profile, "org.example.app")[1] == ["the profile does not allow keychain-access-groups"]
    print("self-test OK: the minimal entitlements are built from the profile and refused when it doesn't allow them")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Sign the C1 bundle for the App Store with zsign.")
    parser.add_argument("app", type=Path, nargs="?")
    parser.add_argument("ipa", type=Path, nargs="?")
    parser.add_argument("--entitlements", type=Path, metavar="FILE",
                        help="the app's own .entitlements file: its keys are signed too, each checked against the profile")
    parser.add_argument("--dry-run", action="store_true", help="check the inputs and print the zsign command")
    parser.add_argument("--self-test", action="store_true", help="check the entitlement rule offline, then exit")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.app and args.ipa:
        main(args.app.resolve(), args.ipa.resolve(), args.dry_run, args.entitlements)
    else:
        parser.error("give the unsigned .app and the output .ipa")

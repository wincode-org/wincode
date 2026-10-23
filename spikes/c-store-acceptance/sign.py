#!/usr/bin/env python3
"""Spike C: sign the C1 bundle for the App Store with zsign (ADR-0009).

  sign.py [--dry-run] <unsigned .app> <out .ipa>

Reads from the folder WINCODE_SPIKE_C_DIR names: dist.key (dist-key.sh), the Apple Distribution certificate (one
.cer) and the App Store profile (one .mobileprovision), both downloaded from the developer portal, and config.json.
zsign gives the main executable the profile's entitlements and every framework none (its archo.cpp signs only
MH_EXECUTE files with entitlements); the script then reads every signature back and checks exactly that.
--dry-run checks the inputs that are there, then prints the zsign command instead of running it.
ZSIGN overrides the zsign path (default: the one build-zsign.sh makes under ~/spikes/spike-c).
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
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import serialization

from asc_preflight import REPO, spike_config

ZSIGN = os.environ.get("ZSIGN", str(Path.home() / "spikes/spike-c/zsign-f6158be9e62a5ce2a53d72b1a6d880880da956c8/bin/zsign"))
loader = importlib.machinery.SourceFileLoader("ipa_diff", str(REPO / "tools/ipa-diff"))
ipa_diff = importlib.util.module_from_spec(importlib.util.spec_from_loader("ipa_diff", loader))
loader.exec_module(ipa_diff)


def one(folder, pattern):
    found = sorted(folder.glob(pattern))
    return found[0] if len(found) == 1 else None


def check_inputs(folder, config, app):
    """The key, certificate and profile, checked against each other and the bundle. Returns (inputs, problems)."""
    now = datetime.datetime.now(datetime.timezone.utc)
    key, cert, profile = folder / "dist.key", one(folder, "*.cer"), one(folder, "*.mobileprovision")
    problems, entitlements, der = [], None, None
    bundle_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
    if bundle_id != config["bundle_id"]:
        problems.append("the bundle's CFBundleIdentifier is not the bundle ID in config.json")
    if not key.is_file():
        problems.append("dist.key is missing (dist-key.sh)")
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
        entitlements = p["Entitlements"]
        print(f"profile: valid until {p['ExpirationDate']:%Y-%m-%d}, entitlements: {', '.join(sorted(entitlements))}")
        if entitlements.get("application-identifier") != f"{p['TeamIdentifier'][0]}.{config['bundle_id']}":
            problems.append("the profile is not for the bundle ID in config.json")
        if "ProvisionedDevices" in p or p.get("ProvisionsAllDevices") or entitlements.get("get-task-allow"):
            problems.append("the profile is not an App Store profile")
        if p["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) < now:
            problems.append("the profile has expired")
        if der is not None and der not in p["DeveloperCertificates"]:
            problems.append("the profile does not include this certificate")
    return (key, cert, profile, entitlements), problems


def check_signed(ipa, entitlements):
    """Every Mach-O is signed; the main executable carries the profile's entitlements, the rest carry none."""
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
        print(f"signed: {path}, entitlements: {', '.join(sorted(got)) or 'none'}")


def main(app, ipa, dry_run):
    folder, config = spike_config()
    (key, cert, profile, entitlements), problems = check_inputs(folder, config, app)
    command = [ZSIGN, "-k", key, "-c", cert or "<certificate .cer>", "-m", profile or "<profile .mobileprovision>",
               "-o", ipa, "-z", "9", "<Payload/ copy of the .app>"]
    if dry_run:
        print("would run: " + " ".join(map(str, command)))
        print("\n".join(f"waiting: {p}" for p in problems) or "inputs OK")
        return
    if problems:
        sys.exit("\n".join(problems))
    # zsign signs a folder in place, so it gets a copy. It zips the whole folder that holds Payload/<app>, so that
    # folder holds nothing else, and its cache goes to the working directory beside it.
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / "bundle/Payload" / app.name
        shutil.copytree(app, copy, symlinks=True)
        command[-1] = copy
        Path(ipa).unlink(missing_ok=True)
        subprocess.run(list(map(str, command)), check=True, cwd=tmp)
    check_signed(ipa, entitlements)
    print(f"signed: {ipa}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Sign the C1 bundle for the App Store with zsign.")
    parser.add_argument("app", type=Path)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--dry-run", action="store_true", help="check the inputs and print the zsign command")
    args = parser.parse_args()
    main(args.app.resolve(), args.ipa.resolve(), args.dry_run)

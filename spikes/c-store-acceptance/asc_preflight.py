#!/usr/bin/env python3
"""Spike C: read-only App Store Connect preflight for the test app. It sends GET requests only.

  asc_preflight.py [--dry-run] [--ipa FILE] [<bundle id>]
                                             PASS or FAIL for: the key works, the app record is found by bundle ID
                                             (default: from WINCODE_SPIKE_C_DIR's config.json), the build number
                                             is higher than every existing build's (INFO shows how many builds
                                             exist and the highest number; the number is the IPA's CFBundleVersion,
                                             else config.json's "build"); then the team's certificates and the
                                             App ID and profiles that match, as one table without names or
                                             identifiers
  asc_preflight.py --self-test               offline: sign a token with a throwaway key and check it against
                                             Apple's documented format

The API key is read from the folder that WINCODE_ASC_KEY_DIR names, outside the repo and outside OneDrive:
AuthKey_<Key ID>.p8 as App Store Connect delivers it, and a file issuer-id holding the Issuer ID. The key, the
Key ID, the Issuer ID and the token are never printed. --dry-run prints each request instead of sending it;
without WINCODE_ASC_KEY_DIR it prints them without signing a token.
"""
import argparse
import base64
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections import Counter
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature, encode_dss_signature

API = "https://api.appstoreconnect.apple.com"
LIFETIME = 600  # seconds; Apple refuses a token that expires more than 20 minutes after it was issued
REPO = Path(__file__).resolve().parents[2]
MASK = {}  # value -> placeholder; spike_config and sign.py add the bundle ID and team ID


def masked(text):
    for value, placeholder in MASK.items():
        text = text.replace(value, placeholder)
    return text


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def private(folder, variable):
    """The folder, resolved; it must be outside the repo and outside OneDrive."""
    folder = Path(folder).resolve()
    if folder == REPO or REPO in folder.parents or any(p.lower().startswith("onedrive") for p in folder.parts):
        sys.exit(f"{variable} must be outside the repo and outside OneDrive")
    return folder


def spike_config():
    """(folder, config) from config.json in the folder WINCODE_SPIKE_C_DIR names: the bundle ID, version and
    build number come from there, never from the repo."""
    if not os.environ.get("WINCODE_SPIKE_C_DIR"):
        sys.exit("set WINCODE_SPIKE_C_DIR to spike C's local folder (docs/spikes/spike-c-store-acceptance.md)")
    folder = private(os.environ["WINCODE_SPIKE_C_DIR"], "WINCODE_SPIKE_C_DIR")
    # utf-8-sig: Notepad may start the file with a byte order mark
    config = json.loads((folder / "config.json").read_text(encoding="utf-8-sig"))
    for key, pattern in (("bundle_id", r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+"), ("version", r"\d+(\.\d+){0,2}"),
                         ("build", r"\d+(\.\d+){0,2}")):
        if not re.fullmatch(pattern, str(config.get(key, ""))):
            sys.exit(f"config.json in WINCODE_SPIKE_C_DIR: {key} is missing or malformed")
    MASK[config["bundle_id"]] = "<bundle ID>"
    return folder, config


def load_key(folder):
    """(private key, Key ID, Issuer ID) from the key folder. No message names the key file or the IDs."""
    folder = private(folder, "WINCODE_ASC_KEY_DIR")
    p8 = list(folder.glob("*.p8"))
    if len(p8) != 1 or not re.fullmatch(r"AuthKey_[A-Z0-9]{10}\.p8", p8[0].name):
        sys.exit("WINCODE_ASC_KEY_DIR must hold one .p8, named AuthKey_<Key ID>.p8 as App Store Connect delivers it")
    issuer_file = folder / "issuer-id"
    issuer = issuer_file.read_text(encoding="utf-8-sig").strip() if issuer_file.is_file() else ""
    if not re.fullmatch(r"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}", issuer, re.I):
        sys.exit("WINCODE_ASC_KEY_DIR must hold a file issuer-id with the Issuer ID (a UUID) on one line")
    key = serialization.load_pem_private_key(p8[0].read_bytes(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
        sys.exit("the .p8 is not an App Store Connect API key (EC P-256)")
    return key, p8[0].stem.removeprefix("AuthKey_"), issuer


def token(key, key_id, issuer, now=None):
    """The ES256 JWT that Apple documents: header alg, kid, typ; claims iss, iat, exp, aud; JWS signature R||S."""
    now = int(time.time() if now is None else now)
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    claims = {"iss": issuer, "iat": now, "exp": now + LIFETIME, "aud": "appstoreconnect-v1"}
    signing_input = ".".join(b64url(json.dumps(part, separators=(",", ":")).encode()) for part in (header, claims))
    r, s = decode_dss_signature(key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256())))
    return f"{signing_input}.{b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def api_error(error, label):
    """An HTTP error with Apple's errors as sent, one per line (each error's own id masked), or the start of the
    answer if it isn't Apple's JSON; masked, and never the request's headers."""
    body = error.read()
    try:
        errors = json.loads(body).get("errors", [])
    except (ValueError, AttributeError):
        errors = []
    lines = [json.dumps({**e, "id": "<error ID>"} if "id" in e else e, ensure_ascii=False) for e in errors]
    return masked(f"{label}: HTTP {error.code}\n" + ("\n".join(lines) or body[:2000].decode(errors="replace")))


def get_all(path, params, bearer, dry_run):
    """All pages of a GET collection. GET only, to Apple's API host only; the token doesn't follow redirects."""
    url, rows = f"{API}{path}?{urllib.parse.urlencode(params)}", []
    while url:
        if not url.startswith(API + "/"):
            sys.exit(f"refusing to send the token outside {API}")
        if dry_run:
            auth = "token signed locally, not shown" if bearer else "no token: WINCODE_ASC_KEY_DIR is not set"
            print(masked(f"GET {urllib.parse.unquote(url)}\n    Authorization: Bearer <{auth}>"))
            return rows
        request = urllib.request.Request(url, method="GET")
        if request.get_method() != "GET":
            sys.exit("abort: the preflight sends GET requests only")
        request.add_unredirected_header("Authorization", f"Bearer {bearer}")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                page = json.load(response)
        except urllib.error.HTTPError as error:
            sys.exit(api_error(error, f"GET {path}"))
        rows += page["data"]
        url = page.get("links", {}).get("next")
    return rows


def build_number(text):
    """'13' -> (13,); '1.2.3' -> (1, 2, 3). Apple compares the dot-separated parts as numbers. None if it isn't one."""
    return tuple(map(int, text.split("."))) if re.fullmatch(r"\d+(\.\d+){0,2}", text or "") else None


def ipa_build_number(ipa):
    """The CFBundleVersion in the IPA's app bundle (Payload/<name>.app/Info.plist)."""
    with zipfile.ZipFile(ipa) as z:
        plists = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(plists) != 1:
            sys.exit(f"{Path(ipa).name}: expected one app bundle in Payload/, found {len(plists)}")
        return plistlib.loads(z.read(plists[0])).get("CFBundleVersion")


def build_number_checks(builds, mine):
    """(INFO line, ok or None) for the app's builds as App Store Connect returned them and this upload's build number.
    ok is None when there is no number to compare. Apple rejects an upload whose number isn't above every earlier one
    for the same version, so equal fails; the first upload (no builds) passes."""
    numbers = sorted(n for n in (build_number(attr(b, "version")) for b in builds) if n)
    highest = ".".join(map(str, numbers[-1])) if numbers else "none"
    info = f"{len(builds)} existing builds, highest build number {highest}"
    if mine is None:
        return info, None
    return info, not numbers or (build_number(mine) or ()) > numbers[-1]


def attr(resource, name):
    return resource["attributes"].get(name) or ""


def table(header, rows):
    widths = [max(map(len, column)) for column in zip(header, *rows)]
    for row in (header, *rows):
        print("  ".join(cell.ljust(width) for cell, width in zip(row, widths)).rstrip())


def preflight(bundle_id, dry_run, ipa=None):
    folder = os.environ.get("WINCODE_ASC_KEY_DIR")
    if not folder and not dry_run:
        sys.exit("set WINCODE_ASC_KEY_DIR to the API key folder (docs/spikes/spike-c-store-acceptance.md)")
    bearer = token(*load_key(folder)) if folder else None

    MASK.setdefault(bundle_id, "<bundle ID>")
    failed = []

    def get(path, params):
        return get_all(path, {**params, "limit": 200}, bearer, dry_run)

    def check(name, ok):
        if not dry_run:
            print(f"{'PASS' if ok else 'FAIL'}  {name}")
            failed.extend([name] * (not ok))

    def info(text):
        if not dry_run:
            print(f"INFO  {text}")

    # The checks come first and need only read access to apps and builds; a key without access to certificates
    # or profiles stops at the table, after them. An HTTP error (a key that doesn't work) stops with Apple's code.
    try:
        apps = get("/v1/apps", {"filter[bundleId]": bundle_id, "fields[apps]": "bundleId"})
    except SystemExit:
        check("the API key works", False)
        raise
    check("the API key works", True)
    app = [a["id"] for a in apps if attr(a, "bundleId") == bundle_id]
    check("the app record is found by bundle ID", len(app) == 1)
    builds = []
    for app_id in app or (["{id of the app record}"] if dry_run else []):
        builds += get(f"/v1/apps/{app_id}/builds", {"fields[builds]": "version,processingState"})
    mine = ipa_build_number(ipa) if ipa else (
        spike_config()[1]["build"] if os.environ.get("WINCODE_SPIKE_C_DIR") else None)
    text, ok = build_number_checks(builds, mine)
    info(text)
    if ok is None:
        info("no IPA or config.json given: the build number was not compared (pass --ipa FILE)")
    else:
        check("the build number is higher than every existing build's", ok)

    certificates = get("/v1/certificates", {"fields[certificates]": "certificateType,expirationDate"})
    bundle_ids = get("/v1/bundleIds", {"filter[identifier]": bundle_id, "fields[bundleIds]": "identifier,platform"})
    exact = [b["id"] for b in bundle_ids if attr(b, "identifier") == bundle_id]
    profiles = []
    for bundle in exact or (["{id of the App ID}"] if dry_run else []):
        profiles += get(f"/v1/bundleIds/{bundle}/profiles", {"fields[profiles]": "profileType,profileState,expirationDate"})
    if dry_run:
        return

    # Names and identifiers stay out of the table: they can carry the team's, client's or app's name.
    rows = [("certificate", attr(c, "certificateType"), "", attr(c, "expirationDate")[:10]) for c in certificates]
    rows += [("App ID", attr(b, "platform"), "", "") for b in bundle_ids if b["id"] in exact]
    rows += [("profile", attr(p, "profileType"), attr(p, "profileState"), attr(p, "expirationDate")[:10]) for p in profiles]
    print()
    table(("KIND", "TYPE", "STATE", "EXPIRES"), rows)
    counts = Counter(attr(c, "certificateType") for c in certificates)
    print(f"\ncertificates: {len(certificates)} ({', '.join(f'{t} {n}' for t, n in sorted(counts.items())) or 'none'}); "
          f"App IDs: {len(exact)}; profiles of that App ID: {len(profiles)}")
    if failed:
        sys.exit(f"{len(failed)} check(s) failed")


def build_number_tests():
    """Fake answers of GET /v1/apps/{id}/builds, in Apple's JSON shape, against the build-number check."""
    def fake(*versions):
        return json.loads(json.dumps({"data": [{"type": "builds", "id": str(i), "attributes": {"version": v}}
                                               for i, v in enumerate(versions)]}))["data"]

    for builds, mine, expected_info, expected_ok in (
            (fake(), "1", "0 existing builds, highest build number none", True),              # first upload
            (fake("1", "9", "10"), "11", "3 existing builds, highest build number 10", True),  # all lower (10 beats 9 as a number, not as text)
            (fake("1", "13"), "13", "2 existing builds, highest build number 13", False),      # equal
            (fake("14", "2"), "13", "2 existing builds, highest build number 14", False),      # an existing build is higher
            (fake("1.2.3"), "1.2.4", "1 existing builds, highest build number 1.2.3", True),   # dotted
            (fake("3"), "x", "1 existing builds, highest build number 3", False),              # not a number
            (fake("3"), None, "1 existing builds, highest build number 3", None)):             # nothing to compare
        assert build_number_checks(builds, mine) == (expected_info, expected_ok), (builds, mine)
    with tempfile.TemporaryDirectory() as tmp:
        ipa = Path(tmp) / "app.ipa"
        with zipfile.ZipFile(ipa, "w") as z:
            z.writestr("Payload/Runner.app/Info.plist", plistlib.dumps({"CFBundleVersion": "13"}))
            z.writestr("Payload/Runner.app/Frameworks/X.framework/Info.plist", plistlib.dumps({"CFBundleVersion": "99"}))
        assert ipa_build_number(ipa) == "13"


def self_test():
    """A throwaway P-256 key stands in for the .p8. The token is checked field by field against Apple's documented
    format, and the openssl command line, a second ES256 implementation, verifies its signature."""
    key = ec.generate_private_key(ec.SECP256R1())
    key_id, issuer, now = "ABCDE12345", "12345678-90ab-cdef-1234-567890abcdef", int(time.time())
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / f"AuthKey_{key_id}.p8").write_bytes(key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        (tmp / "issuer-id").write_text(issuer + "\n")
        loaded = load_key(tmp)
        assert loaded[1:] == (key_id, issuer)
        jwt = token(*loaded, now=now)

        def decode(part):
            return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))

        header, claims, signature = jwt.split(".")
        assert "=" not in jwt, "base64url without padding"
        assert json.loads(decode(header)) == {"alg": "ES256", "kid": key_id, "typ": "JWT"}
        assert json.loads(decode(claims)) == {"iss": issuer, "iat": now, "exp": now + LIFETIME,
                                              "aud": "appstoreconnect-v1"}
        assert 0 < LIFETIME <= 20 * 60, "Apple refuses tokens that live longer than 20 minutes"
        raw = decode(signature)
        assert len(raw) == 64, "an ES256 JWS signature is R||S, 32 bytes each, not DER"
        (tmp / "public.pem").write_bytes(key.public_key().public_bytes(
            serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))
        (tmp / "signature.der").write_bytes(
            encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big")))
        (tmp / "signing-input").write_text(f"{header}.{claims}")
        verify = subprocess.run(["openssl", "dgst", "-sha256", "-verify", tmp / "public.pem",
                                 "-signature", tmp / "signature.der", tmp / "signing-input"],
                                capture_output=True, text=True)
        assert verify.returncode == 0 and "Verified OK" in verify.stdout, verify.stdout + verify.stderr
        for refused in (REPO / "spikes", tmp / "OneDrive" / "keys"):
            try:
                load_key(refused)
            except SystemExit:
                continue
            raise AssertionError(f"accepted a key folder at {refused}")
    build_number_tests()
    print("self-test OK: header, claims and signature follow Apple's token format, and openssl verifies the signature; "
          "the build-number check handles no, lower, equal and higher builds")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Read-only App Store Connect preflight for spike C (GET only).")
    parser.add_argument("bundle_id", nargs="?", help="the test app's bundle ID (default: from WINCODE_SPIKE_C_DIR)")
    parser.add_argument("--ipa", help="the IPA whose CFBundleVersion is compared with the existing builds")
    parser.add_argument("--dry-run", action="store_true", help="print each request instead of sending it")
    parser.add_argument("--self-test", action="store_true", help="check the token format offline, then exit")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        preflight(args.bundle_id or spike_config()[1]["bundle_id"], args.dry_run, args.ipa)

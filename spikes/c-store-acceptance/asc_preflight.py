#!/usr/bin/env python3
"""Spike C: read-only App Store Connect preflight for the test app. It sends GET requests only.

  asc_preflight.py [--dry-run] <bundle id>   the team's certificates, and the App IDs, apps and profiles that
                                             match <bundle id>, as one table
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
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature, encode_dss_signature

API = "https://api.appstoreconnect.apple.com"
LIFETIME = 600  # seconds; Apple refuses a token that expires more than 20 minutes after it was issued
REPO = Path(__file__).resolve().parents[2]


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def load_key(folder):
    """(private key, Key ID, Issuer ID) from the key folder. No message names the key file or the IDs."""
    folder = Path(folder).resolve()
    if folder == REPO or REPO in folder.parents or any(p.lower().startswith("onedrive") for p in folder.parts):
        sys.exit("WINCODE_ASC_KEY_DIR must be outside the repo and outside OneDrive")
    p8 = list(folder.glob("*.p8"))
    if len(p8) != 1 or not re.fullmatch(r"AuthKey_[A-Z0-9]{10}\.p8", p8[0].name):
        sys.exit("WINCODE_ASC_KEY_DIR must hold one .p8, named AuthKey_<Key ID>.p8 as App Store Connect delivers it")
    issuer_file = folder / "issuer-id"
    issuer = issuer_file.read_text().strip() if issuer_file.is_file() else ""
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


def get_all(path, params, bearer, dry_run):
    """All pages of a GET collection. GET only, to Apple's API host only; the token doesn't follow redirects."""
    url, rows = f"{API}{path}?{urllib.parse.urlencode(params)}", []
    while url:
        if not url.startswith(API + "/"):
            sys.exit(f"refusing to send the token outside {API}")
        if dry_run:
            auth = "token signed locally, not shown" if bearer else "no token: WINCODE_ASC_KEY_DIR is not set"
            print(f"GET {urllib.parse.unquote(url)}\n    Authorization: Bearer <{auth}>")
            return rows
        request = urllib.request.Request(url, method="GET")
        request.add_unredirected_header("Authorization", f"Bearer {bearer}")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                page = json.load(response)
        except urllib.error.HTTPError as error:
            try:
                errors = json.load(error).get("errors", [])
            except ValueError:
                errors = []
            sys.exit(f"GET {path}: HTTP {error.code} "
                     + "; ".join(f"{e.get('code')}: {e.get('detail') or e.get('title')}" for e in errors))
        rows += page["data"]
        url = page.get("links", {}).get("next")
    return rows


def attr(resource, name):
    return resource["attributes"].get(name) or ""


def table(header, rows):
    widths = [max(map(len, column)) for column in zip(header, *rows)]
    for row in (header, *rows):
        print("  ".join(cell.ljust(width) for cell, width in zip(row, widths)).rstrip())


def preflight(bundle_id, dry_run):
    folder = os.environ.get("WINCODE_ASC_KEY_DIR")
    if not folder and not dry_run:
        sys.exit("set WINCODE_ASC_KEY_DIR to the API key folder (docs/spikes/spike-c-store-acceptance.md)")
    bearer = token(*load_key(folder)) if folder else None

    def get(path, params):
        return get_all(path, {**params, "limit": 200}, bearer, dry_run)

    certificates = get("/v1/certificates", {"fields[certificates]": "certificateType,expirationDate"})
    bundle_ids = get("/v1/bundleIds", {"filter[identifier]": bundle_id, "fields[bundleIds]": "identifier,name,platform"})
    apps = get("/v1/apps", {"filter[bundleId]": bundle_id, "fields[apps]": "name,bundleId"})
    exact = [b["id"] for b in bundle_ids if attr(b, "identifier") == bundle_id]
    profiles = []
    for bundle in exact or (["{id of the App ID}"] if dry_run else []):
        profiles += get(f"/v1/bundleIds/{bundle}/profiles",
                        {"fields[profiles]": "name,profileType,profileState,expirationDate"})
    if dry_run:
        return

    rows = [("certificate", attr(c, "certificateType"), "", "", "", attr(c, "expirationDate")[:10]) for c in certificates]
    rows += [("App ID", attr(b, "platform"), attr(b, "name"), attr(b, "identifier"), "", "") for b in bundle_ids]
    rows += [("app", "", attr(a, "name"), attr(a, "bundleId"), "", "") for a in apps]
    rows += [("profile", attr(p, "profileType"), attr(p, "name"), bundle_id, attr(p, "profileState"),
              attr(p, "expirationDate")[:10]) for p in profiles]
    table(("KIND", "TYPE", "NAME", "IDENTIFIER", "STATE", "EXPIRES"), rows)
    counts = Counter(attr(c, "certificateType") for c in certificates)
    print(f"\ncertificates: {len(certificates)} ({', '.join(f'{t} {n}' for t, n in sorted(counts.items())) or 'none'})")
    print(f"App IDs matching: {len(bundle_ids)}, exactly: {len(exact)}; apps: {len(apps)}; "
          f"profiles of that App ID: {len(profiles)}")


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
    print("self-test OK: header, claims and signature follow Apple's token format, and openssl verifies the signature")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Read-only App Store Connect preflight for spike C (GET only).")
    parser.add_argument("bundle_id", nargs="?", help="the test app's bundle ID")
    parser.add_argument("--dry-run", action="store_true", help="print each request instead of sending it")
    parser.add_argument("--self-test", action="store_true", help="check the token format offline, then exit")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.bundle_id:
        preflight(args.bundle_id, args.dry_run)
    else:
        parser.error("give the test app's bundle ID, or --self-test")

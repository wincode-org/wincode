#!/usr/bin/env python3
"""Spike C: upload the signed IPA through the App Store Connect Build Uploads API. This is the only write to Apple
that spike C's code makes, and a STOP comes before it (docs/spikes/spike-c-store-acceptance.md).

  asc_upload.py [--dry-run] <signed .ipa>

  1. GET   /v1/apps?filter[bundleId]=…        the app record's ID (the app record is made on the website)
  2. POST  /v1/buildUploads                   the app, version, build number, platform IOS
  3. POST  /v1/buildUploadFiles               the IPA's name and size, uti com.apple.ipa, assetType ASSET
  4. the answer's uploadOperations            each part of the IPA, sent as Apple's answer says, without the token
  5. PATCH /v1/buildUploadFiles/{id}          uploaded: true, with the IPA's MD5
  6. GET   /v1/buildUploads/{id}              every 30 s until the state leaves AWAITING_UPLOAD and PROCESSING;
                                              prints Apple's errors, warnings and infos

The bundle ID, version and build number come from config.json in WINCODE_SPIKE_C_DIR and must match the IPA. The
API key comes from WINCODE_ASC_KEY_DIR, as for asc_preflight.py. --dry-run prints each request instead of sending
it, never the token; IDs and parts that only Apple's answers give are shown as placeholders. The request bodies
follow App Store Connect API 4.5.1.
"""
import argparse
import hashlib
import json
import os
import plistlib
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

from asc_preflight import API, api_error, get_all, load_key, spike_config, token

POLL, PATIENCE = 30, 3600  # seconds


def check_ipa(ipa, config):
    """The IPA's Info.plist must carry the config's bundle ID, version and build number, and the IPA a profile."""
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        plists = [n for n in names if n.count("/") == 2 and n.startswith("Payload/") and n.endswith(".app/Info.plist")]
        if len(plists) != 1:
            sys.exit(f"{ipa}: expected one Payload/<name>.app")
        info = plistlib.loads(z.read(plists[0]))
        if plists[0].replace("Info.plist", "embedded.mobileprovision") not in names:
            sys.exit(f"{ipa} is not signed with a profile (sign.py)")
    for key, want in (("CFBundleIdentifier", config["bundle_id"]), ("CFBundleShortVersionString", config["version"]),
                      ("CFBundleVersion", config["build"])):
        if info.get(key) != want:
            sys.exit(f"{ipa}: {key} does not match config.json")


def show(method, path, body=None):
    print(f"{method} {API}{path}" + (f"\n    {json.dumps(body)}" if body else ""))


def main(ipa, dry_run):
    _, config = spike_config()
    check_ipa(ipa, config)
    folder = os.environ.get("WINCODE_ASC_KEY_DIR")
    if not folder and not dry_run:
        sys.exit("set WINCODE_ASC_KEY_DIR to the API key folder (docs/spikes/spike-c-store-acceptance.md)")
    key = load_key(folder) if folder else None
    data = ipa.read_bytes()

    def call(method, path, body=None):
        """One JSON request to the API with a fresh token; the token never follows a redirect."""
        show(method, path, body)
        request = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                         headers={"Content-Type": "application/json"} if body else {})
        request.add_unredirected_header("Authorization", f"Bearer {token(*key)}")
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            sys.exit(api_error(error, f"{method} {path}"))

    apps = get_all("/v1/apps", {"filter[bundleId]": config["bundle_id"], "fields[apps]": "bundleId", "limit": 200},
                   token(*key) if key else None, dry_run)
    app_id = next((a["id"] for a in apps if a["attributes"]["bundleId"] == config["bundle_id"]), None)
    if not dry_run and app_id is None:
        sys.exit("no app record with this bundle ID: it is made on the App Store Connect website first")
    upload = {"data": {"type": "buildUploads",
                       "attributes": {"cfBundleShortVersionString": config["version"],
                                      "cfBundleVersion": config["build"], "platform": "IOS"},
                       "relationships": {"app": {"data": {"type": "apps", "id": app_id or "{id of the app record}"}}}}}
    file = {"data": {"type": "buildUploadFiles",
                     "attributes": {"assetType": "ASSET", "fileName": ipa.name, "fileSize": len(data),
                                    "uti": "com.apple.ipa"},
                     "relationships": {"buildUpload": {"data": {"type": "buildUploads", "id": "{id of the build upload}"}}}}}
    # ponytail: the checksum is a hex MD5, as asset uploads take it; if Apple wants another form, its answer says so
    commit = {"data": {"type": "buildUploadFiles", "id": "{id of the upload file}",
                       "attributes": {"uploaded": True,
                                      "sourceFileChecksums": {"file": {"hash": hashlib.md5(data).hexdigest(),
                                                                       "algorithm": "MD5"}}}}}
    if dry_run:
        show("POST", "/v1/buildUploads", upload)
        show("POST", "/v1/buildUploadFiles", file)
        print(f"<each uploadOperations entry of the answer>: its method and URL, its byte range of the {len(data)}-byte "
              "IPA and its requestHeaders; no token")
        show("PATCH", "/v1/buildUploadFiles/{id of the upload file}", commit)
        show("GET", "/v1/buildUploads/{id of the build upload}")
        print("Authorization on every API request: Bearer <"
              + ("token signed locally, not shown" if key else "no token: WINCODE_ASC_KEY_DIR is not set") + ">")
        return

    upload_id = call("POST", "/v1/buildUploads", upload)["data"]["id"]
    file["data"]["relationships"]["buildUpload"]["data"]["id"] = upload_id
    reserved = call("POST", "/v1/buildUploadFiles", file)["data"]
    for op in reserved["attributes"]["uploadOperations"]:
        part = data[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
        print(f"{op['method']} part {op.get('partNumber', 1)}: {len(part)} bytes")
        with urllib.request.urlopen(urllib.request.Request(op["url"], data=part, method=op["method"], headers=headers),
                                    timeout=600):
            pass
    commit["data"]["id"] = reserved["id"]
    call("PATCH", f"/v1/buildUploadFiles/{reserved['id']}", commit)

    deadline, state = time.time() + PATIENCE, {}
    while time.time() < deadline:
        state = call("GET", f"/v1/buildUploads/{upload_id}")["data"]["attributes"]["state"]
        print(f"state: {state.get('state')}")
        if state.get("state") not in ("AWAITING_UPLOAD", "PROCESSING"):
            break
        time.sleep(POLL)
    for kind in ("errors", "warnings", "infos"):
        for detail in state.get(kind) or []:
            print(f"{kind[:-1]}: {detail.get('code')}: {detail.get('description')}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Upload the signed IPA through the Build Uploads API.")
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--dry-run", action="store_true", help="print each request instead of sending it")
    args = parser.parse_args()
    main(args.ipa.resolve(), args.dry_run)

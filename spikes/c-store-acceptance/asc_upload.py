#!/usr/bin/env python3
"""Spike C: upload the signed IPA through the App Store Connect Build Uploads API. This is the only write to Apple
that spike C's code makes, and a STOP comes before it (docs/spikes/spike-c-store-acceptance.md).

  asc_upload.py [--dry-run] <signed .ipa>

  1. GET   /v1/apps?filter[bundleId]=…        the app record's ID (the app record is made on the website)
  2. POST  /v1/buildUploads                   the app, version, build number, platform IOS
  3. POST  /v1/buildUploadFiles               the IPA's name and size, uti com.apple.ipa, assetType ASSET
  4. the answer's uploadOperations            each part of the IPA, sent as Apple's answer says, without the token
  5. PATCH /v1/buildUploadFiles/{id}          uploaded: true, with the IPA's MD5
  6. GET   /v1/buildUploads/{id}              with its build and file, every 30 s for up to 15 minutes after the
                                              commit, until the upload fails or the build leaves PROCESSING

The bundle ID, version and build number come from config.json in WINCODE_SPIKE_C_DIR and must match the IPA. The
API key comes from WINCODE_ASC_KEY_DIR, as for asc_preflight.py. --dry-run prints each request instead of sending
it, never the token; IDs and parts that only Apple's answers give are shown as placeholders. A real run prints each
step and each change of state with its UTC time, and every message Apple gives as sent; IDs are masked. Any refusal
stops it, and nothing is retried. The request bodies follow App Store Connect API 4.5.1.
"""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

from asc_preflight import API, MASK, api_error, get_all, load_key, masked, spike_config, token

POLL, PATIENCE = 30, 15 * 60  # seconds; the wait for Apple's processing result starts at the commit
STOPPED = "stopped, nothing is retried"


def log(message):
    print(f"{datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M:%S} UTC  {masked(message)}", flush=True)


def check_ipa(ipa, config):
    """The IPA's Info.plist must carry the config's bundle ID, version and build number, and the IPA a profile,
    whose team ID is masked from then on."""
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        plists = [n for n in names if n.count("/") == 2 and n.startswith("Payload/") and n.endswith(".app/Info.plist")]
        if len(plists) != 1:
            sys.exit(f"{ipa}: expected one Payload/<name>.app")
        info = plistlib.loads(z.read(plists[0]))
        profile = plists[0].replace("Info.plist", "embedded.mobileprovision")
        if profile not in names:
            sys.exit(f"{ipa} is not signed with a profile (sign.py)")
        blob = z.read(profile)  # a CMS-signed plist; its XML is read in place, without checking Apple's signature
        team = plistlib.loads(blob[blob.index(b"<?xml"):blob.index(b"</plist>") + 8])["TeamIdentifier"][0]
        MASK[team] = "<team ID>"
    for key, want in (("CFBundleIdentifier", config["bundle_id"]), ("CFBundleShortVersionString", config["version"]),
                      ("CFBundleVersion", config["build"])):
        if info.get(key) != want:
            sys.exit(f"{ipa}: {key} does not match config.json")


def show(method, path, body=None):
    print(masked(f"{method} {API}{path}" + (f"\n    {json.dumps(body)}" if body else "")))


def main(ipa, dry_run):
    _, config = spike_config()
    check_ipa(ipa, config)
    folder = os.environ.get("WINCODE_ASC_KEY_DIR")
    if not folder and not dry_run:
        sys.exit("set WINCODE_ASC_KEY_DIR to the API key folder (docs/spikes/spike-c-store-acceptance.md)")
    key = load_key(folder) if folder else None
    data = ipa.read_bytes()

    def call(method, path, body=None):
        """One JSON request to the API with a fresh token; the token never follows a redirect. Any error stops."""
        request = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                         headers={"Content-Type": "application/json"} if body else {})
        request.add_unredirected_header("Authorization", f"Bearer {token(*key)}")
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            sys.exit(f"{api_error(error, f'{method} {path}')}\n{STOPPED}")
        except OSError as error:  # no answer: the request may or may not have reached Apple
            sys.exit(masked(f"{method} {path}: {error}\n{STOPPED}"))

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
    query = urllib.parse.urlencode({"include": "build,assetFile", "fields[builds]": "processingState",
                                    "fields[buildUploadFiles]": "assetDeliveryState"})
    if dry_run:
        show("POST", "/v1/buildUploads", upload)
        show("POST", "/v1/buildUploadFiles", file)
        print(f"<each uploadOperations entry of the answer>: its method and URL, its byte range of the {len(data)}-byte "
              "IPA and its requestHeaders; no token")
        show("PATCH", "/v1/buildUploadFiles/{id of the upload file}", commit)
        show("GET", "/v1/buildUploads/{id of the build upload}?" + urllib.parse.unquote(query))
        print(f"    every {POLL} s, for up to {PATIENCE // 60} minutes after the commit")
        print("Authorization on every API request: Bearer <"
              + ("token signed locally, not shown" if key else "no token: WINCODE_ASC_KEY_DIR is not set") + ">")
        return

    MASK[app_id] = "<app record ID>"
    log("app record found")
    upload_id = call("POST", "/v1/buildUploads", upload)["data"]["id"]
    MASK[upload_id] = "<build upload ID>"
    log(f"build upload created: version {config['version']}, build {config['build']}")
    file["data"]["relationships"]["buildUpload"]["data"]["id"] = upload_id
    reserved = call("POST", "/v1/buildUploadFiles", file)["data"]
    MASK[reserved["id"]] = "<upload file ID>"
    operations = reserved["attributes"].get("uploadOperations") or []
    log(f"file reserved: {len(operations)} part(s) to send")
    if not operations:
        sys.exit(f"Apple's answer gives no uploadOperations\n{STOPPED}")
    for op in operations:
        number, part = op.get("partNumber", 1), data[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
        try:
            with urllib.request.urlopen(urllib.request.Request(op["url"], data=part, method=op["method"],
                                                               headers=headers), timeout=600):
                pass
        except urllib.error.HTTPError as error:  # a part's URL is a signed, temporary link: it is never printed
            answer = error.read(2000).decode(errors="replace")
            sys.exit(masked(re.sub(r"https?://[^\s<>\"']+", "<URL>", f"part {number}: HTTP {error.code} {error.reason}\n"
                                                             f"{answer}\n{STOPPED}")))
        except OSError as error:
            sys.exit(masked(re.sub(r"https?://[^\s<>\"']+", "<URL>", f"part {number}: {error}\n{STOPPED}")))
        log(f"part {number} sent: {len(part)} bytes")
    commit["data"]["id"] = reserved["id"]
    delivery = call("PATCH", f"/v1/buildUploadFiles/{reserved['id']}", commit)["data"]["attributes"]
    log(f"commit accepted; file: {json.dumps(delivery.get('assetDeliveryState'), ensure_ascii=False)}")

    # Every refusal stops the script: call() exits on an HTTP error, a failed state ends here. Nothing is retried.
    deadline, seen, said = time.time() + PATIENCE, None, set()
    while True:
        answer = call("GET", f"/v1/buildUploads/{upload_id}?{query}")
        status = answer["data"]["attributes"].get("state") or {}
        included = {i["type"]: i.get("attributes") or {} for i in answer.get("included") or []}
        delivery = included.get("buildUploadFiles", {}).get("assetDeliveryState") or {}
        state, file_state, build = status.get("state"), delivery.get("state"), included.get("builds", {}).get("processingState")
        if (state, file_state, build) != seen:
            seen = (state, file_state, build)
            log(f"upload {state}, file {file_state}, build {build or 'not created yet'}")
        for source, details in (("upload", status), ("file", delivery)):
            for kind in ("errors", "warnings", "infos"):
                for detail in details.get(kind) or []:
                    line = f"{source} {kind[:-1]}: {json.dumps(detail, ensure_ascii=False)}"
                    if line not in said:
                        said.add(line)
                        log(line)
        if "FAILED" in (state, file_state) or build in ("FAILED", "INVALID", "VALID"):
            break
        if time.time() + POLL > deadline:
            log(f"no final result after {PATIENCE // 60} minutes; stopped waiting")
            return
        time.sleep(POLL)
    if build != "VALID":
        sys.exit(f"upload {state}, file {file_state}, build {build}: {STOPPED}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Upload the signed IPA through the Build Uploads API.")
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--dry-run", action="store_true", help="print each request instead of sending it")
    args = parser.parse_args()
    main(args.ipa.resolve(), args.dry_run)

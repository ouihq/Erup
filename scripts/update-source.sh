#!/usr/bin/env bash
# Keeps source.json in step with a built IPA: version, build number, size, SHA-256 and date are read from the file
# itself, so the source never disagrees with the download.
#
#   scripts/update-source.sh [path/to/Erup-unsigned.ipa] ["Release notes for this version"]
#
# For a version that is already listed, only its size, hash, build and date are refreshed. For a new version, an
# entry is added at the top of "versions" (AltStore treats the first entry as the latest release).
set -euo pipefail

cd "$(dirname "$0")/.."
ipa="${1:-build/Erup-unsigned.ipa}"
notes="${2:-}"
[[ -f "$ipa" ]] || { echo "No IPA at $ipa. Build one first." >&2; exit 1; }

python3 -I - "$ipa" "$notes" <<'PY'
import datetime, hashlib, json, os, plistlib, shutil, sys, zipfile

ipa, notes = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(ipa) as archive:
    plist_path = next(n for n in archive.namelist()
                      if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2)
    info = plistlib.loads(archive.read(plist_path))

version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
size = os.path.getsize(ipa)
with open(ipa, "rb") as handle:
    sha256 = hashlib.sha256(handle.read()).hexdigest()
today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
url = f"https://github.com/ouihq/Erup/releases/download/v{version}/Erup.ipa"

with open("source.json") as handle:
    source = json.load(handle)
app = source["apps"][0]
versions = app["versions"]
entry = next((v for v in versions if v["version"] == version), None)
if entry is None:
    entry = {"version": version, "localizedDescription": notes or "See the release page for what changed.", "minOSVersion": info.get("MinimumOSVersion", "18.0")}
    versions.insert(0, entry)
elif notes:
    entry["localizedDescription"] = notes
entry.update({"buildVersion": build, "date": today, "downloadURL": url, "size": size, "sha256": sha256})
# Keep the key order AltStore documents.
order = ["version", "buildVersion", "date", "localizedDescription", "downloadURL", "size", "sha256", "minOSVersion"]
versions[versions.index(entry)] = {k: entry[k] for k in order if k in entry}

# Older AltStore builds read the latest version from the app itself.
latest = versions[0]
app.update({"version": latest["version"], "versionDate": latest["date"],
            "versionDescription": latest["localizedDescription"], "downloadURL": latest["downloadURL"], "size": latest["size"]})

with open("source.json", "w") as handle:
    json.dump(source, handle, indent=2, ensure_ascii=False)
    handle.write("\n")

shutil.copyfile(ipa, "build/Erup.ipa")
print(f"source.json: Erup {version} ({build}), {size:,} bytes, sha256 {sha256}, {today}")
print("Upload build/Erup.ipa as the asset 'Erup.ipa' of the GitHub release v" + version + ".")
PY

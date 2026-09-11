#!/bin/bash
set -euo pipefail

# Takes the notarized .app produced by the signing partner. Produces reviewable
# release files locally; never publishes or exports the private signing key.
if [[ $# -ne 2 ]]; then
    echo "Usage: bash scripts/prepare-sparkle-update.sh /path/Linklet.app /path/Sparkle/bin" >&2
    exit 2
fi

app_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
sparkle_bin="$(cd "$2" && pwd)"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_plist="$app_path/Contents/Info.plist"

[[ -d "$app_path" && "$app_path" == *.app ]] || { echo "Expected a .app bundle" >&2; exit 1; }
[[ -x "$sparkle_bin/generate_appcast" ]] || { echo "Sparkle tools not found" >&2; exit 1; }

bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app_plist")
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app_plist")
build=$(/usr/bin/plutil -extract CFBundleVersion raw "$app_plist")
public_key=$(/usr/bin/plutil -extract SUPublicEDKey raw "$app_plist")
expected_key=$(/usr/bin/plutil -extract SUPublicEDKey raw "$repo_root/Linklet/Linklet/Info.plist")
feed_url=$(/usr/bin/plutil -extract SUFeedURL raw "$app_plist")
[[ "$bundle_id" == Linklet && "$public_key" == "$expected_key" ]] || { echo "Wrong app or Sparkle public key" >&2; exit 1; }
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ && "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Invalid release version/build" >&2; exit 1; }
[[ "$feed_url" == https://alybo.github.io/Linklet/appcast.xml ]] || { echo "Unexpected update feed" >&2; exit 1; }

/usr/bin/python3 - "$repo_root/updates/appcast.xml" "$build" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))
for item in ET.parse(sys.argv[1]).findall("./channel/item"):
    previous = item.findtext("s:version", namespaces=ns)
    if previous and version(sys.argv[2]) <= version(previous):
        sys.exit("Build number must exceed every published build")
PY

# Stop before packaging if the app is a development build or lacks its ticket.
/usr/bin/codesign --verify --deep --strict "$app_path"
/usr/sbin/spctl --assess --type execute "$app_path"
/usr/bin/xcrun stapler validate "$app_path"

output_dir="$repo_root/build/sparkle/$version-$build"
[[ ! -e "$output_dir" ]] || { echo "Output already exists: $output_dir" >&2; exit 1; }
mkdir -p "$output_dir"
archive_name="Linklet-$version.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_dir/$archive_name"
cp "$repo_root/updates/appcast.xml" "$output_dir/appcast.xml"

"$sparkle_bin/generate_appcast" \
    --account app.linklet.sparkle \
    --maximum-deltas 0 \
    --download-url-prefix "https://github.com/alybo/Linklet/releases/download/v$version/" \
    "$output_dir"

/usr/bin/python3 - "$output_dir/appcast.xml" "$build" "$archive_name" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
for item in ET.parse(sys.argv[1]).findall("./channel/item"):
    if item.findtext("s:version", namespaces=ns) == sys.argv[2]:
        enclosure = item.find("enclosure")
        if (enclosure is not None
                and enclosure.get("{%(s)s}edSignature" % ns)
                and enclosure.get("url", "").endswith("/" + sys.argv[3])):
            break
else:
    sys.exit("No signed update for this build was generated; do not publish")
PY

(cd "$output_dir" && /usr/bin/shasum -a 256 "$archive_name" > SHA256SUMS.txt)
echo "Prepared: $output_dir"
echo "Review the generated appcast. Publish the ZIP with corresponding sources first."
echo "Only then copy appcast.xml to updates/ and publish the feed."

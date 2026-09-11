#!/bin/bash
set -euo pipefail

# The signing partner supplies the final notarized DMG and complete sources.
# Only release/ is uploaded as GitHub Release assets; feed/ goes to Pages.
if [[ $# -ne 3 ]]; then
    echo "Usage: bash scripts/prepare-sparkle-update.sh /path/Linklet.dmg /path/Linklet-source.tar.gz /path/Sparkle/bin" >&2
    exit 2
fi

dmg_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
source_path="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
sparkle_bin="$(cd "$3" && pwd)"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

[[ -f "$dmg_path" && "$dmg_path" == *.dmg ]] || { echo "Expected a final .dmg file" >&2; exit 1; }
[[ -f "$source_path" && "$source_path" == *.tar.gz ]] || { echo "Expected a complete source .tar.gz archive" >&2; exit 1; }
[[ -x "$sparkle_bin/generate_appcast" ]] || { echo "Sparkle tools not found" >&2; exit 1; }
# This checks archive readability, not completeness of corresponding source.
/usr/bin/tar -tzf "$source_path" >/dev/null

# All Apple signing/notarization/stapling must finish before Sparkle signs bytes.
/usr/bin/codesign --verify --strict "$dmg_path"
/usr/sbin/spctl --assess --type open --context context:primary-signature "$dmg_path"
/usr/bin/xcrun stapler validate "$dmg_path"

mount_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/linklet-release.XXXXXX")
mounted=0
cleanup() {
    if [[ "$mounted" == 1 ]]; then
        /usr/bin/hdiutil detach "$mount_dir" -quiet || echo "Please eject $mount_dir manually" >&2
    fi
    rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" -quiet
mounted=1
shopt -s nullglob
apps=("$mount_dir"/*.app)
[[ ${#apps[@]} -eq 1 && ! -L "${apps[0]}" ]] || { echo "DMG must contain exactly one app at its root" >&2; exit 1; }
app_path="${apps[0]}"
app_plist="$app_path/Contents/Info.plist"

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

/usr/bin/codesign --verify --deep --strict "$app_path"
/usr/sbin/spctl --assess --type execute "$app_path"
/usr/bin/xcrun stapler validate "$app_path"
/usr/bin/hdiutil detach "$mount_dir" -quiet
mounted=0

output_dir="$repo_root/build/sparkle/$version-$build"
[[ ! -e "$output_dir" ]] || { echo "Output already exists: $output_dir" >&2; exit 1; }
mkdir -p "$output_dir/release" "$output_dir/feed"
archive_name="Linklet-$version.dmg"
source_name="Linklet-$version-source.tar.gz"
cp "$dmg_path" "$output_dir/release/$archive_name"
cp "$repo_root/updates/appcast.xml" "$output_dir/release/appcast.xml"

# Generate while this directory contains only the app DMG. The source tarball
# must not be scanned by Sparkle as another application update.
"$sparkle_bin/generate_appcast" \
    --account app.linklet.sparkle \
    --maximum-deltas 0 \
    --download-url-prefix "https://github.com/alybo/Linklet/releases/download/v$version/" \
    "$output_dir/release"

/usr/bin/python3 - "$output_dir/release/appcast.xml" "$build" "$version" "$archive_name" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
expected_url = f"https://github.com/alybo/Linklet/releases/download/v{sys.argv[3]}/{sys.argv[4]}"
for item in ET.parse(sys.argv[1]).findall("./channel/item"):
    if item.findtext("s:version", namespaces=ns) == sys.argv[2]:
        enclosure = item.find("enclosure")
        if (enclosure is not None
                and enclosure.get("{%(s)s}edSignature" % ns)
                and enclosure.get("url") == expected_url):
            break
else:
    sys.exit("No signed DMG update for this build was generated; do not publish")
PY

cmp "$dmg_path" "$output_dir/release/$archive_name"
mv "$output_dir/release/appcast.xml" "$output_dir/feed/appcast.xml"
cp "$source_path" "$output_dir/release/$source_name"

# Checksums go into the release description, not another downloadable asset.
{
    echo "Для установки скачайте **$archive_name** и перетащите Linklet в Программы."
    echo
    echo 'Контрольные суммы SHA-256:'
    echo '```text'
    (cd "$output_dir/release" && /usr/bin/shasum -a 256 "$archive_name" "$source_name")
    echo '```'
} > "$output_dir/release-description.md"
echo "Upload ONLY these two release assets:"
echo "$output_dir/release/$archive_name"
echo "$output_dir/release/$source_name"
echo "Use $output_dir/release-description.md in the release description."
echo "After publishing both assets, copy $output_dir/feed/appcast.xml to updates/."

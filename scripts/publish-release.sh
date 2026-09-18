#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$script_dir/release-common.sh"
repo_root="$(release_repo_root)"

usage() {
    cat <<'EOF'
Usage: scripts/publish-release.sh [--resume] [--dry-run]

Publishes the tagged Linklet commit using its cached preflight receipt. The
command archives a universal app, directly notarizes the app and DMG with
notarytool, prepares Sparkle, publishes the two GitHub assets, then publishes
the appcast last.

Environment:
  LINKLET_NOTARY_PROFILE     notarytool keychain profile (default: scribe-notary)
  LINKLET_SIGNING_IDENTITY   Developer ID Application identity
  LINKLET_DEVELOPMENT_TEAM   Apple team ID (default: V5JQ998A2L)

Options:
  --resume   reuse already verified local artifacts or finish appcast publication
  --dry-run  print the complete plan without building or changing external state
EOF
}

resume=0
dry_run=0
while (( $# )); do
    case "$1" in
        --resume) resume=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

started_at=$SECONDS
version="$(release_value "$repo_root" version)"
build="$(release_value "$repo_root" build)"
tag="v$version"
commit="$(git -C "$repo_root" rev-parse HEAD)"
notary_profile="${LINKLET_NOTARY_PROFILE:-scribe-notary}"
signing_identity="${LINKLET_SIGNING_IDENTITY:-Developer ID Application: Ruslan Said Galiev (V5JQ998A2L)}"
development_team="${LINKLET_DEVELOPMENT_TEAM:-V5JQ998A2L}"
preflight_root="$repo_root/build/release-preflight/$version-$build"
manifest="$preflight_root/manifest.json"
derived_data="$repo_root/build/release-cache/$commit/DerivedData"
release_root="$repo_root/build/releases/$version-$build"
archive_path="$release_root/Linklet-$version.xcarchive"
app_path="$archive_path/Products/Applications/Linklet.app"
app_zip="$release_root/Linklet-$version-notary.zip"
dmg_path="$release_root/Linklet-$version.dmg"
sparkle_output="$repo_root/build/sparkle/$version-$build"

if (( dry_run )); then
    receipt_state="missing (run scripts/release-preflight.sh first)"
    if [[ -f "$manifest" ]]; then
        receipt_state="present (real publish will verify commit, tag, version, build, checks, and source hash)"
    fi
    cat <<EOF
Linklet $version (build $build), $tag at $commit
Preflight: $receipt_state
Notary profile: $notary_profile
Signing identity: $signing_identity

Publish plan:
  1. validate the cached preflight receipt; never rerun heavy tests here
  2. archive one universal Developer ID app (arm64 + x86_64)
  3. submit the app ZIP directly with: xcrun notarytool submit --keychain-profile $notary_profile --wait
  4. staple and audit the app; build and sign the DMG
  5. submit the DMG directly with the same notarytool profile; staple and audit it
  6. sign the immutable DMG for Sparkle and prepare exactly two release assets
  7. publish/recover the GitHub Release, verify remote downloads, then push appcast last

No build, notarization, GitHub write, or file write was performed.
EOF
    exit 0
fi

for command_name in git xcodebuild gh curl; do
    release_require_command "$command_name"
done

release_step "Validate cached preflight"
/usr/bin/python3 "$repo_root/scripts/release_manifest.py" verify \
    --repo-root "$repo_root" --manifest "$manifest" >/dev/null
source_relative="$(/usr/bin/python3 "$repo_root/scripts/release_manifest.py" verify \
    --repo-root "$repo_root" --manifest "$manifest" --field sourceArchive)"
source_archive="$repo_root/$source_relative"
[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ]] || {
    echo "Tracked files changed after preflight" >&2
    exit 1
}
git -C "$repo_root" fetch --quiet origin \
    "+refs/heads/main:refs/remotes/origin/main"
origin_head="$(git -C "$repo_root" rev-parse origin/main)"
if [[ "$origin_head" != "$commit" ]]; then
    (( resume )) || {
        echo "origin/main changed after preflight; rerun the release from the new tagged commit" >&2
        exit 1
    }
    git -C "$repo_root" merge-base --is-ancestor "$commit" "$origin_head" || {
        echo "origin/main no longer descends from the release commit" >&2
        exit 1
    }
    remote_changes="$(git -C "$repo_root" diff --name-only "$commit..$origin_head")"
    [[ "$remote_changes" == updates/appcast.xml ]] || {
        echo "origin/main contains changes beyond the resumed release appcast: $remote_changes" >&2
        exit 1
    }
fi

release_step "Validate signing and direct notarization credentials"
/usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$signing_identity\"" || {
    echo "Developer ID identity not found: $signing_identity" >&2
    exit 1
}
xcrun notarytool history --keychain-profile "$notary_profile" --output-format json >/dev/null
gh auth status >/dev/null

if [[ -e "$release_root" && $resume -eq 0 ]]; then
    echo "Release workspace already exists: $release_root" >&2
    echo "Use --resume to verify and continue it." >&2
    exit 1
fi
mkdir -p "$release_root"

release_step "Archive universal Developer ID app"
if (( resume )) && [[ -d "$app_path" ]] && /usr/bin/codesign --verify --deep --strict "$app_path" 2>/dev/null; then
    echo "Reusing verified archive: $archive_path"
else
    [[ "$archive_path" == "$release_root/Linklet-$version.xcarchive" ]] || exit 1
    /bin/rm -rf "$archive_path"
    xcodebuild \
        -project "$repo_root/Linklet/Linklet.xcodeproj" \
        -scheme Linklet \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$derived_data" \
        -archivePath "$archive_path" \
        'ARCHS=arm64 x86_64' \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$development_team" \
        CODE_SIGN_IDENTITY="$signing_identity" \
        archive
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
app_archs="$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/Linklet")"
[[ " $app_archs " == *" arm64 "* && " $app_archs " == *" x86_64 "* ]] || {
    echo "Expected universal app, got: $app_archs" >&2
    exit 1
}
entitlements="$(/usr/bin/codesign -d --entitlements - "$app_path" 2>&1 || true)"
[[ "$entitlements" != *"com.apple.security.get-task-allow"* ]] || {
    echo "Release app contains get-task-allow" >&2
    exit 1
}
[[ "$entitlements" != *"com.apple.security.cs.disable-library-validation"* ]] || {
    echo "Release app disables library validation" >&2
    exit 1
}

release_step "Notarize and staple app directly"
if (( resume )) && xcrun stapler validate "$app_path" >/dev/null 2>&1; then
    echo "Reusing stapled app."
else
    /bin/rm -f "$app_zip"
    /usr/bin/ditto -c -k --keepParent "$app_path" "$app_zip"
    xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$app_path"
fi
xcrun stapler validate "$app_path"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app_path"

release_step "Build and sign DMG"
if (( resume )) && [[ -f "$dmg_path" ]] && /usr/bin/codesign --verify --strict "$dmg_path" 2>/dev/null; then
    echo "Reusing signed DMG."
else
    staging="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/linklet-dmg.XXXXXX")"
    trap '/bin/rm -rf "$staging"' EXIT INT TERM
    /usr/bin/ditto "$app_path" "$staging/Linklet.app"
    /bin/ln -s /Applications "$staging/Applications"
    /bin/rm -f "$dmg_path"
    /usr/bin/hdiutil create -volname Linklet -srcfolder "$staging" -format UDZO -ov "$dmg_path"
    /usr/bin/codesign --force --timestamp --sign "$signing_identity" "$dmg_path"
    /bin/rm -rf "$staging"
    trap - EXIT INT TERM
fi
/usr/bin/codesign --verify --strict --verbose=2 "$dmg_path"

release_step "Notarize and staple DMG directly"
if (( resume )) && xcrun stapler validate "$dmg_path" >/dev/null 2>&1; then
    echo "Reusing stapled DMG."
else
    xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg_path"
fi
xcrun stapler validate "$dmg_path"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"

release_step "Verify final DMG contents"
mount_path="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/linklet-mount.XXXXXX")"
trap 'release_cleanup_mount "$mount_path"' EXIT INT TERM
/usr/bin/hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_path" -quiet
/usr/bin/cmp "$app_path/Contents/MacOS/Linklet" "$mount_path/Linklet.app/Contents/MacOS/Linklet"
/usr/bin/codesign --verify --deep --strict "$mount_path/Linklet.app"
release_cleanup_mount "$mount_path"
trap - EXIT INT TERM

release_step "Prepare Sparkle feed and two release assets"
sparkle_bin="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$sparkle_bin/generate_appcast" ]] || {
    echo "Sparkle tools missing from cached preflight: $sparkle_bin" >&2
    exit 1
}
if [[ -e "$sparkle_output" ]]; then
    (( resume )) || { echo "Sparkle output already exists; use --resume" >&2; exit 1; }
    [[ "$sparkle_output" == "$repo_root/build/sparkle/$version-$build" ]] || exit 1
    /bin/rm -rf "$sparkle_output"
fi
bash "$repo_root/scripts/prepare-sparkle-update.sh" "$dmg_path" "$source_archive" "$sparkle_bin"
release_dmg="$sparkle_output/release/Linklet-$version.dmg"
release_source="$sparkle_output/release/Linklet-$version-source.tar.gz"
release_notes="$sparkle_output/release-description.md"
feed="$sparkle_output/feed/appcast.xml"

release_step "Create or recover GitHub Release"
release_json="$(gh release view "$tag" --json isDraft,url 2>/dev/null || true)"
is_draft=""
if [[ -n "$release_json" ]]; then
    is_draft="$(printf '%s' "$release_json" | /usr/bin/python3 -c 'import json,sys; print(str(json.load(sys.stdin)["isDraft"]).lower())')"
fi
if [[ "$is_draft" == false ]]; then
    (( resume )) || { echo "$tag is already public; use --resume to verify and finish its appcast" >&2; exit 1; }
    echo "Public release exists; verifying instead of replacing it."
elif [[ "$is_draft" == true ]]; then
    gh release edit "$tag" --title "Linklet $version" --notes-file "$release_notes"
    while IFS= read -r asset_name; do
        [[ -z "$asset_name" ]] || gh release delete-asset "$tag" "$asset_name" --yes
    done < <(gh release view "$tag" --json assets --jq '.assets[].name')
    gh release upload "$tag" "$release_dmg" "$release_source"
    gh release edit "$tag" --draft=false
else
    gh release create "$tag" "$release_dmg" "$release_source" \
        --draft --verify-tag --title "Linklet $version" --notes-file "$release_notes"
    gh release edit "$tag" --draft=false
fi

release_step "Verify public release bytes and asset set"
assets_json="$(gh release view "$tag" --json assets,url)"
/usr/bin/python3 -c '
import json, sys
payload = json.load(sys.stdin)
names = sorted(asset["name"] for asset in payload["assets"])
expected = sorted([f"Linklet-{sys.argv[1]}.dmg", f"Linklet-{sys.argv[1]}-source.tar.gz"])
if names != expected:
    raise SystemExit(f"Wrong release assets: {names}, expected {expected}")
' "$version" <<< "$assets_json"
download_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/linklet-download.XXXXXX")"
trap '/bin/rm -rf "$download_dir"' EXIT INT TERM
gh release download "$tag" --dir "$download_dir" --pattern "Linklet-$version.dmg" --pattern "Linklet-$version-source.tar.gz"
/usr/bin/cmp "$release_dmg" "$download_dir/Linklet-$version.dmg"
/usr/bin/cmp "$release_source" "$download_dir/Linklet-$version-source.tar.gz"
/bin/rm -rf "$download_dir"
trap - EXIT INT TERM

release_step "Publish appcast last"
feed_checkout="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/linklet-feed.XXXXXX")"
trap '/usr/bin/find "$feed_checkout" -depth -delete 2>/dev/null || true' EXIT INT TERM
origin_url="$(git -C "$repo_root" remote get-url origin)"
git clone --quiet --branch main --single-branch "$origin_url" "$feed_checkout"
git -C "$feed_checkout" merge-base --is-ancestor "$commit" HEAD || {
    echo "Current main no longer descends from release commit $commit" >&2
    exit 1
}
feed_changes="$(git -C "$feed_checkout" diff --name-only "$commit..HEAD")"
[[ -z "$feed_changes" || "$feed_changes" == updates/appcast.xml ]] || {
    echo "Current main has unrelated post-tag changes: $feed_changes" >&2
    exit 1
}
if /usr/bin/cmp -s "$feed" "$feed_checkout/updates/appcast.xml"; then
    echo "Appcast is already current."
else
    /bin/cp "$feed" "$feed_checkout/updates/appcast.xml"
    git -C "$feed_checkout" add updates/appcast.xml
    staged="$(git -C "$feed_checkout" diff --cached --name-only)"
    [[ "$staged" == updates/appcast.xml ]] || {
        echo "Unexpected staged files: $staged" >&2
        exit 1
    }
    git -C "$feed_checkout" commit -m "Publish Sparkle feed for Linklet $version"
    git -C "$feed_checkout" push origin HEAD:main
fi
/usr/bin/find "$feed_checkout" -depth -delete
trap - EXIT INT TERM

release_step "Verify public Pages feed"
public_feed="https://alybo.github.io/Linklet/appcast.xml"
published=0
for attempt in {1..24}; do
    if /usr/bin/curl -fsSL "$public_feed" | /usr/bin/grep -Fq "releases/download/$tag/Linklet-$version.dmg"; then
        published=1
        break
    fi
    /bin/sleep 5
done
(( published )) || { echo "Pages did not publish the new appcast within two minutes" >&2; exit 1; }

release_url="$(printf '%s' "$(gh release view "$tag" --json url)" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')"
echo
echo "Published $release_url"
echo "DMG SHA-256: $(release_sha256 "$release_dmg")"
echo "Source SHA-256: $(release_sha256 "$release_source")"
echo "Appcast: $public_feed"
echo "Elapsed: $(( SECONDS - started_at )) seconds"

#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$script_dir/release-common.sh"
repo_root="$(release_repo_root)"

usage() {
    cat <<'EOF'
Usage: scripts/release-preflight.sh [--force] [--dry-run]

Runs expensive release checks once for the tagged commit and writes a hash-bound
receipt under build/release-preflight/. A valid receipt is reused automatically.

  --force    rerun checks while retaining Xcode/SwiftPM build caches
  --dry-run  print the checks and cache paths without running or writing them
EOF
}

force=0
dry_run=0
while (( $# )); do
    case "$1" in
        --force) force=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

version="$(release_value "$repo_root" version)"
build="$(release_value "$repo_root" build)"
tag="v$version"
commit="$(git -C "$repo_root" rev-parse HEAD)"
cache_root="$repo_root/build/release-preflight/$version-$build"
derived_data="$repo_root/build/release-cache/$commit/DerivedData"
source_archive="$cache_root/Linklet-$version-source.tar.gz"
manifest="$cache_root/manifest.json"

if (( dry_run )); then
    cat <<EOF
Linklet $version (build $build), $tag at $commit
Cached DerivedData: $derived_data
Preflight receipt: $manifest

Planned checks:
  1. tagged commit, clean tree, pushed tag and main
  2. Python release/Sparkle tests
  3. Xcode app tests (reusing DerivedData)
  4. Raycast tests, typecheck, and source lint
  5. complete corresponding-source archive with pinned dependencies
  6. offline build from that archive

No files or external state were changed.
EOF
    exit 0
fi

release_require_command git
release_require_command xcodebuild
release_require_command npm

if (( ! force )) && [[ -f "$manifest" ]]; then
    if /usr/bin/python3 "$repo_root/scripts/release_manifest.py" verify \
        --repo-root "$repo_root" --manifest "$manifest" >/dev/null; then
        echo "Reusing verified preflight receipt: $manifest"
        exit 0
    fi
    echo "Cached receipt is stale; rerunning preflight." >&2
fi

release_step "Verify immutable release input"
[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ]] || {
    echo "Tracked files are dirty; commit release input before preflight" >&2
    exit 1
}
[[ "$(git -C "$repo_root" rev-list -n 1 "$tag" 2>/dev/null || true)" == "$commit" ]] || {
    echo "$tag must point to HEAD ($commit)" >&2
    exit 1
}
git -C "$repo_root" fetch --quiet origin \
    "+refs/heads/main:refs/remotes/origin/main" \
    "refs/tags/$tag:refs/tags/$tag"
[[ "$(git -C "$repo_root" rev-parse origin/main)" == "$commit" ]] || {
    echo "origin/main must equal tagged release commit before preflight" >&2
    exit 1
}
remote_tag="$(git -C "$repo_root" ls-remote --tags origin "refs/tags/$tag" | /usr/bin/awk '{print $1}')"
[[ "$remote_tag" == "$commit" ]] || {
    echo "Remote $tag is missing or does not point to $commit" >&2
    exit 1
}

mkdir -p "$cache_root" "$derived_data"

release_step "Run Python release tests"
/usr/bin/python3 -m unittest discover -s "$repo_root/scripts/tests" -p 'test_*.py'

release_step "Run Xcode tests with reusable build cache"
xcodebuild \
    -project "$repo_root/Linklet/Linklet.xcodeproj" \
    -scheme Linklet \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -parallel-testing-enabled NO \
    test

release_step "Run Raycast checks"
(
    cd "$repo_root/integrations/raycast-linklet"
    npm ci
    npm test
    npm run typecheck
    npm run lint:source
)

release_step "Create complete corresponding-source archive"
/usr/bin/python3 "$repo_root/scripts/build_source_archive.py" \
    --repo-root "$repo_root" \
    --derived-data "$derived_data" \
    --output "$source_archive"
/usr/bin/tar -tzf "$source_archive" >/dev/null

release_step "Build once from the self-contained source archive"
source_check="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/linklet-source-check.XXXXXX")"
trap '/bin/rm -rf "$source_check"' EXIT INT TERM
/usr/bin/tar -xzf "$source_archive" -C "$source_check"
source_root="$source_check/Linklet-$version-source"
/usr/bin/python3 "$source_root/use-local-packages.py"
xcodebuild \
    -project "$source_root/Linklet/Linklet.xcodeproj" \
    -scheme Linklet \
    -configuration Release \
    -derivedDataPath "$source_check/DerivedData" \
    -disableAutomaticPackageResolution \
    'ARCHS=arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- \
    build
/bin/rm -rf "$source_check"
trap - EXIT INT TERM

release_step "Write hash-bound preflight receipt"
/usr/bin/python3 "$repo_root/scripts/release_manifest.py" create \
    --repo-root "$repo_root" \
    --source "$source_archive" \
    --output "$manifest"
echo "Preflight passed and cached: $manifest"

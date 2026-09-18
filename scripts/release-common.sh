#!/bin/zsh

set -euo pipefail

RELEASE_COMMON_DIR="${${(%):-%N}:A:h}"

release_repo_root() {
    cd "$RELEASE_COMMON_DIR/.." && pwd
}

release_value() {
    local root="$1"
    local field="$2"
    /usr/bin/python3 "$root/scripts/release_manifest.py" project --repo-root "$root" --field "$field"
}

release_step() {
    local message="$1"
    printf '\n==> %s\n' "$message"
}

release_require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        return 1
    }
}

release_sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

release_cleanup_mount() {
    local mount_path="$1"
    if /sbin/mount | /usr/bin/grep -Fq " on $mount_path "; then
        /usr/bin/hdiutil detach "$mount_path" -quiet || true
    fi
    /bin/rmdir "$mount_path" 2>/dev/null || true
}

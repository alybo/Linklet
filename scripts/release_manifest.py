#!/usr/bin/env python3
"""Create and validate the cached release-preflight receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


SCHEMA_VERSION = 1
REQUIRED_CHECKS = (
    "pythonTests",
    "xcodeTests",
    "raycastTests",
    "sourceArchive",
)


class ManifestError(RuntimeError):
    pass


def run_git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


def project_values(root: Path) -> tuple[str, str]:
    project = root / "Linklet/Linklet.xcodeproj/project.pbxproj"
    text = project.read_text(encoding="utf-8")

    def unique_value(name: str) -> str:
        values = set(re.findall(rf"\b{name}\s*=\s*([^;]+);", text))
        if len(values) != 1:
            raise ManifestError(f"Expected exactly one {name}, found {sorted(values)}")
        return values.pop().strip()

    version = unique_value("MARKETING_VERSION")
    build = unique_value("CURRENT_PROJECT_VERSION")
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", version):
        raise ManifestError(f"Invalid MARKETING_VERSION: {version}")
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", build):
        raise ManifestError(f"Invalid CURRENT_PROJECT_VERSION: {build}")
    return version, build


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_state(root: Path) -> dict[str, str]:
    version, build = project_values(root)
    commit = run_git(root, "rev-parse", "HEAD")
    tag = f"v{version}"
    try:
        tag_commit = run_git(root, "rev-list", "-n", "1", tag)
    except subprocess.CalledProcessError as error:
        raise ManifestError(f"Missing release tag {tag}") from error
    if tag_commit != commit:
        raise ManifestError(f"{tag} points to {tag_commit}, but HEAD is {commit}")
    return {"tag": tag, "commit": commit, "version": version, "build": build}


def create_manifest(root: Path, source: Path, output: Path) -> None:
    state = expected_state(root)
    if not source.is_file():
        raise ManifestError(f"Missing source archive: {source}")
    try:
        source_value = str(source.resolve().relative_to(root.resolve()))
    except ValueError as error:
        raise ManifestError("Source archive must be inside the repository build directory") from error
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        **state,
        "sourceArchive": source_value,
        "sourceSHA256": sha256(source),
        "checks": {name: "passed" for name in REQUIRED_CHECKS},
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def validate_manifest(root: Path, manifest_path: Path) -> dict[str, object]:
    if not manifest_path.is_file():
        raise ManifestError(f"Missing preflight receipt: {manifest_path}")
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as error:
        raise ManifestError(f"Unreadable preflight receipt: {manifest_path}") from error
    if payload.get("schemaVersion") != SCHEMA_VERSION:
        raise ManifestError("Unsupported preflight receipt schema")

    state = expected_state(root)
    for key, expected in state.items():
        if payload.get(key) != expected:
            raise ManifestError(
                f"Stale preflight receipt: {key} is {payload.get(key)!r}, expected {expected!r}"
            )
    checks = payload.get("checks")
    if not isinstance(checks, dict):
        raise ManifestError("Preflight receipt has no checks")
    for name in REQUIRED_CHECKS:
        if checks.get(name) != "passed":
            raise ManifestError(f"Preflight check did not pass: {name}")

    source_value = payload.get("sourceArchive")
    if not isinstance(source_value, str) or not source_value:
        raise ManifestError("Preflight receipt has no source archive")
    source = (root / source_value).resolve()
    try:
        source.relative_to(root.resolve())
    except ValueError as error:
        raise ManifestError("Source archive escapes the repository") from error
    if not source.is_file():
        raise ManifestError(f"Source archive disappeared: {source}")
    actual_hash = sha256(source)
    if payload.get("sourceSHA256") != actual_hash:
        raise ManifestError("Source archive changed after preflight")
    return payload


def parser() -> argparse.ArgumentParser:
    root_parser = argparse.ArgumentParser(description=__doc__)
    commands = root_parser.add_subparsers(dest="command", required=True)

    project = commands.add_parser("project", help="print version/build as JSON or one field")
    project.add_argument("--repo-root", type=Path, required=True)
    project.add_argument("--field", choices=("version", "build", "tag", "commit"))

    create = commands.add_parser("create", help="write a successful preflight receipt")
    create.add_argument("--repo-root", type=Path, required=True)
    create.add_argument("--source", type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)

    verify = commands.add_parser("verify", help="validate a preflight receipt and source hash")
    verify.add_argument("--repo-root", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--field", choices=("sourceArchive", "version", "build", "tag", "commit"))
    return root_parser


def main() -> int:
    args = parser().parse_args()
    try:
        root = args.repo_root.resolve()
        if args.command == "project":
            version, build = project_values(root)
            values = {
                "version": version,
                "build": build,
                "tag": f"v{version}",
                "commit": run_git(root, "rev-parse", "HEAD"),
            }
            print(values[args.field] if args.field else json.dumps(values, sort_keys=True))
        elif args.command == "create":
            create_manifest(root, args.source.resolve(), args.output.resolve())
            print(args.output.resolve())
        else:
            payload = validate_manifest(root, args.manifest.resolve())
            print(payload[args.field] if args.field else json.dumps(payload, sort_keys=True))
    except (ManifestError, subprocess.CalledProcessError) as error:
        print(f"release manifest: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

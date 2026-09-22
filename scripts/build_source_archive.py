#!/usr/bin/env python3
"""Build Linklet's complete corresponding-source archive from resolved packages."""

from __future__ import annotations

import argparse
import gzip
import json
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

from release_manifest import project_values, run_git


LOCAL_OVERRIDE = r'''#!/usr/bin/env python3
from pathlib import Path
import re

root = Path(__file__).resolve().parent
project = root / "Linklet/Linklet.xcodeproj/project.pbxproj"
text = project.read_text()
for name in ["Sparkle", "SafariConverterLib"]:
    pattern = (
        r'isa = XCRemoteSwiftPackageReference; repositoryURL = "[^";]*/'
        + name
        + r'(?:\.git)?"; requirement = \{[^}]+\};'
    )
    text, count = re.subn(
        pattern,
        'isa = XCLocalSwiftPackageReference; relativePath = "../vendor/' + name + '";',
        text,
    )
    if count != 1:
        raise SystemExit("Expected one remote reference: " + name)
project.write_text(text)

for name in ["SafariConverterLib", "swift-psl"]:
    manifest = root / "vendor" / name / "Package.swift"
    text = manifest.read_text()
    for dependency in ["PunycodeSwift", "swift-argument-parser", "swift-psl"]:
        text = re.sub(
            r'\.package\(url: "[^";]*/' + dependency + r'(?:\.git)?", [^\n]+\)',
            '.package(path: "../' + dependency + '")',
            text,
        )
    manifest.write_text(text)

manifest = root / "vendor/Sparkle/Package.swift"
text = manifest.read_text()
needle = "url: url,\n            checksum: checksum"
if needle not in text:
    raise SystemExit("Sparkle artifact declaration changed")
manifest.write_text(text.replace(needle, 'path: "../SparkleArtifacts/Sparkle.xcframework"'))
print("Local dependency overrides installed. Use -disableAutomaticPackageResolution.")
'''


def command(*args: str, cwd: Path | None = None) -> str:
    result = subprocess.run(
        args,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


def copy_without_git(source: Path, destination: Path) -> None:
    shutil.copytree(
        source,
        destination,
        symlinks=True,
        ignore=shutil.ignore_patterns(".git"),
    )


def source_build_text(version: str, build: str) -> str:
    return f"""# Linklet {version} corresponding source (build {build})

This archive contains the exact tracked source from tag v{version}, every resolved Swift package (including transitive dependencies), their licenses, and the matching Sparkle XCFramework used by SwiftPM. Publisher certificates, private release keys, credentials, user preferences, and build caches are not included.

Requirements: macOS, Xcode 26 or newer, command-line tools, and Python 3. The built app runs on macOS 14 or newer.

## Build with included dependencies

Extract to a writable directory, then run:

```sh
python3 use-local-packages.py
xcodebuild -project Linklet/Linklet.xcodeproj -scheme Linklet -configuration Release -derivedDataPath build/local -disableAutomaticPackageResolution 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
```

`use-local-packages.py` modifies only the extracted copy, replacing remote package references with the included `vendor/` paths. Re-extract the archive to return to the original tagged source. The Raycast integration is optional and has its own lockfile under `integrations/raycast-linklet`.
"""


def normalized_tar_info(info: tarfile.TarInfo, epoch: int) -> tarfile.TarInfo:
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = epoch
    if info.isfile():
        # SwiftPM checkouts may be read-only, but use-local-packages.py must
        # rewrite their manifests in the extracted corresponding source.
        info.mode |= 0o200
    return info


def build_archive(repo: Path, derived_data: Path, output: Path) -> None:
    version, build = project_values(repo)
    tag = f"v{version}"
    commit = run_git(repo, "rev-parse", "HEAD")
    if run_git(repo, "rev-list", "-n", "1", tag) != commit:
        raise SystemExit(f"{tag} must point to HEAD before creating corresponding source")

    package_file = repo / "Linklet/Linklet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    resolved = json.loads(package_file.read_text(encoding="utf-8"))
    pins = resolved.get("pins", [])
    workspace_file = derived_data / "SourcePackages/workspace-state.json"
    workspace = json.loads(workspace_file.read_text(encoding="utf-8"))["object"]
    dependencies = {
        item["packageRef"]["identity"]: item for item in workspace.get("dependencies", [])
    }
    checkouts = derived_data / "SourcePackages/checkouts"

    output.parent.mkdir(parents=True, exist_ok=True)
    archive_root_name = f"Linklet-{version}-source"
    with tempfile.TemporaryDirectory(prefix="linklet-source-", dir=output.parent) as temporary:
        temporary_path = Path(temporary)
        git_tar = temporary_path / "tracked.tar"
        subprocess.run(
            ["git", "-C", str(repo), "archive", "--format=tar", f"--prefix={archive_root_name}/", "-o", str(git_tar), "HEAD"],
            check=True,
        )
        subprocess.run(["/usr/bin/tar", "-xf", str(git_tar), "-C", str(temporary_path)], check=True)
        root = temporary_path / archive_root_name
        vendor = root / "vendor"
        vendor.mkdir()

        for pin in pins:
            identity = pin["identity"]
            dependency = dependencies.get(identity)
            if dependency is None:
                raise SystemExit(f"Resolved package is absent from DerivedData: {identity}")
            subpath = dependency["subpath"]
            source = checkouts / subpath
            expected_revision = pin["state"]["revision"]
            actual_revision = command("git", "-C", str(source), "rev-parse", "HEAD")
            if actual_revision != expected_revision:
                raise SystemExit(
                    f"Wrong checkout for {identity}: {actual_revision}, expected {expected_revision}"
                )
            if not any(source.glob("LICENSE*")):
                raise SystemExit(f"No root license found for dependency: {identity}")
            copy_without_git(source, vendor / subpath)

        artifacts = workspace.get("artifacts", [])
        sparkle_artifact = next(
            (Path(item["path"]) for item in artifacts if item["packageRef"]["identity"] == "sparkle"),
            None,
        )
        if sparkle_artifact is None or not sparkle_artifact.is_dir():
            raise SystemExit("Resolved Sparkle XCFramework is missing")
        copy_without_git(sparkle_artifact, vendor / "SparkleArtifacts/Sparkle.xcframework")

        (root / "DEPENDENCIES.json").write_text(
            json.dumps(pins, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        (root / "SOURCE-BUILD.md").write_text(source_build_text(version, build), encoding="utf-8")
        helper = root / "use-local-packages.py"
        helper.write_text(LOCAL_OVERRIDE, encoding="utf-8")
        helper.chmod(0o755)

        epoch = int(run_git(repo, "show", "-s", "--format=%ct", "HEAD"))
        if output.exists():
            output.unlink()
        with output.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=epoch) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", dereference=False) as archive:
                    archive.add(
                        root,
                        arcname=archive_root_name,
                        recursive=True,
                        filter=lambda item: normalized_tar_info(item, epoch),
                    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build_archive(args.repo_root.resolve(), args.derived_data.resolve(), args.output.resolve())
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

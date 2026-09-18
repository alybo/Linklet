import json
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
MANIFEST = REPO / "scripts/release_manifest.py"
PREFLIGHT = REPO / "scripts/release-preflight.sh"
PUBLISH = REPO / "scripts/publish-release.sh"
SOURCE_BUILDER = REPO / "scripts/build_source_archive.py"
SCHEME = REPO / "Linklet/Linklet.xcodeproj/xcshareddata/xcschemes/Linklet.xcscheme"


class ReleaseManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        project = self.root / "Linklet/Linklet.xcodeproj"
        project.mkdir(parents=True)
        (project / "project.pbxproj").write_text(
            "MARKETING_VERSION = 2.0;\nCURRENT_PROJECT_VERSION = 7;\n"
            "MARKETING_VERSION = 2.0;\nCURRENT_PROJECT_VERSION = 7;\n",
            encoding="utf-8",
        )
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.email", "test@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "fixture"], check=True)
        subprocess.run(["git", "-C", str(self.root), "tag", "v2.0"], check=True)
        build = self.root / "build/release-preflight/2.0-7"
        build.mkdir(parents=True)
        self.source = build / "Linklet-2.0-source.tar.gz"
        self.source.write_bytes(b"complete source")
        self.receipt = build / "manifest.json"

    def tearDown(self):
        self.temporary.cleanup()

    def run_manifest(self, *arguments, check=True):
        return subprocess.run(
            ["python3", str(MANIFEST), *map(str, arguments)],
            check=check,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def create(self):
        self.run_manifest(
            "create",
            "--repo-root",
            self.root,
            "--source",
            self.source,
            "--output",
            self.receipt,
        )

    def verify(self):
        return self.run_manifest(
            "verify", "--repo-root", self.root, "--manifest", self.receipt, check=False
        )

    def test_valid_receipt_is_accepted(self):
        self.create()
        self.assertEqual(self.verify().returncode, 0)

    def test_changed_source_is_rejected(self):
        self.create()
        self.source.write_bytes(b"changed source")
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed after preflight", result.stderr)

    def test_changed_commit_is_rejected(self):
        self.create()
        (self.root / "later.txt").write_text("later", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "later"], check=True)
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("v2.0 points to", result.stderr)

    def test_changed_version_or_build_is_rejected(self):
        self.create()
        project = self.root / "Linklet/Linklet.xcodeproj/project.pbxproj"
        project.write_text(
            project.read_text(encoding="utf-8").replace("CURRENT_PROJECT_VERSION = 7", "CURRENT_PROJECT_VERSION = 8"),
            encoding="utf-8",
        )
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build", result.stderr)

    def test_failed_check_is_rejected(self):
        self.create()
        payload = json.loads(self.receipt.read_text(encoding="utf-8"))
        payload["checks"]["xcodeTests"] = "failed"
        self.receipt.write_text(json.dumps(payload), encoding="utf-8")
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("xcodeTests", result.stderr)


class PublishScriptTests(unittest.TestCase):
    def test_direct_notarytool_workflow_has_no_organizer_carrier(self):
        text = PUBLISH.read_text(encoding="utf-8")
        self.assertGreaterEqual(text.count('xcrun notarytool submit'), 2)
        self.assertIn('--keychain-profile "$notary_profile" --wait', text)
        self.assertNotIn("-exportNotarizedApp", text)
        self.assertNotIn("carrier", text.lower())
        self.assertNotIn("upload-package", text)

    def test_dry_run_does_not_invoke_external_release_tools(self):
        result = subprocess.run(
            ["zsh", str(PUBLISH), "--dry-run"],
            cwd=REPO,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertIn("No build, notarization, GitHub write, or file write", result.stdout)
        self.assertIn("notarytool submit", result.stdout)
        self.assertIn("appcast last", result.stdout)

    def test_xcode_tests_use_non_hanging_direct_launcher(self):
        text = SCHEME.read_text(encoding="utf-8")
        self.assertIn('selectedLauncherIdentifier = "Xcode.IDEFoundation.Launcher.PosixSpawn"', text)
        self.assertIn('parallelizable = "NO"', text)

    def test_main_fetch_ignores_clone_specific_fetch_refspec(self):
        explicit_refspec = '"+refs/heads/main:refs/remotes/origin/main"'
        self.assertIn(explicit_refspec, PREFLIGHT.read_text(encoding="utf-8"))
        self.assertIn(explicit_refspec, PUBLISH.read_text(encoding="utf-8"))


class SourceArchiveTests(unittest.TestCase):
    def test_archive_contains_exact_dependency_and_is_reproducible(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            project = root / "Linklet/Linklet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
            project.mkdir(parents=True)
            (root / "Linklet/Linklet.xcodeproj/project.pbxproj").write_text(
                "MARKETING_VERSION = 2.0;\nCURRENT_PROJECT_VERSION = 7;\n",
                encoding="utf-8",
            )
            checkout = Path(temporary) / "DerivedData/SourcePackages/checkouts/Sparkle"
            checkout.mkdir(parents=True)
            (checkout / "LICENSE").write_text("license", encoding="utf-8")
            (checkout / "Package.swift").write_text("package", encoding="utf-8")
            subprocess.run(["git", "init", "-q", str(checkout)], check=True)
            subprocess.run(["git", "-C", str(checkout), "config", "user.name", "Test"], check=True)
            subprocess.run(["git", "-C", str(checkout), "config", "user.email", "test@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(checkout), "add", "."], check=True)
            subprocess.run(["git", "-C", str(checkout), "commit", "-qm", "dependency"], check=True)
            revision = subprocess.check_output(
                ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
            ).strip()
            pins = [{
                "identity": "sparkle",
                "kind": "remoteSourceControl",
                "location": "https://example.invalid/Sparkle",
                "state": {"revision": revision, "version": "2.9.6"},
            }]
            (project / "Package.resolved").write_text(
                json.dumps({"version": 3, "pins": pins}), encoding="utf-8"
            )
            artifact = Path(temporary) / "DerivedData/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework"
            artifact.mkdir(parents=True)
            (artifact / "Info.plist").write_text("fixture", encoding="utf-8")
            workspace = Path(temporary) / "DerivedData/SourcePackages/workspace-state.json"
            workspace.parent.mkdir(parents=True, exist_ok=True)
            workspace.write_text(json.dumps({
                "version": 7,
                "object": {
                    "dependencies": [{
                        "packageRef": {"identity": "sparkle"},
                        "subpath": "Sparkle",
                    }],
                    "artifacts": [{
                        "packageRef": {"identity": "sparkle"},
                        "path": str(artifact),
                    }],
                },
            }), encoding="utf-8")

            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.name", "Test"], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.email", "test@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(["git", "-C", str(root), "commit", "-qm", "fixture"], check=True)
            subprocess.run(["git", "-C", str(root), "tag", "v2.0"], check=True)

            first = Path(temporary) / "first.tar.gz"
            second = Path(temporary) / "second.tar.gz"
            for output in (first, second):
                subprocess.run([
                    "python3", str(SOURCE_BUILDER),
                    "--repo-root", str(root),
                    "--derived-data", str(Path(temporary) / "DerivedData"),
                    "--output", str(output),
                ], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first, "r:gz") as archive:
                names = set(archive.getnames())
            self.assertIn("Linklet-2.0-source/vendor/Sparkle/LICENSE", names)
            self.assertIn(
                "Linklet-2.0-source/vendor/SparkleArtifacts/Sparkle.xcframework/Info.plist",
                names,
            )
            self.assertIn("Linklet-2.0-source/SOURCE-BUILD.md", names)


if __name__ == "__main__":
    unittest.main()

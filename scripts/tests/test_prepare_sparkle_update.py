"""Test release layout and failure handling with fake signing/mounting tools.

This does not replace notarization or a real Sparkle installation test on macOS.
"""
import hashlib
import io
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PrepareDMGReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="linklet-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "updates").mkdir()
        (self.root / "Linklet/Linklet").mkdir(parents=True)
        self.fixture = self.root / "fixture/Linklet.app/Contents"
        self.fixture.mkdir(parents=True)
        self.info = {
            "CFBundleIdentifier": "Linklet",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "2",
            "SUPublicEDKey": "fixture-public-key",
            "SUFeedURL": "https://alybo.github.io/Linklet/appcast.xml",
            "SUEnableAutomaticChecks": True,
            "SUAutomaticallyUpdate": True,
        }
        for path in (self.fixture / "Info.plist", self.root / "Linklet/Linklet/Info.plist"):
            path.write_bytes(plistlib.dumps(self.info))
        (self.root / "updates/appcast.xml").write_text('<rss version="2.0"><channel/></rss>')
        self.dmg = self.root / "input with spaces.dmg"
        self.dmg.write_bytes(b"final DMG bytes; copying must preserve these")
        self.source = self.root / "complete source.tar.gz"
        with tarfile.open(self.source, "w:gz") as archive:
            entry = tarfile.TarInfo("source/README.md")
            content = b"source archive fixture"
            entry.size = len(content)
            archive.addfile(entry, io.BytesIO(content))
        self.bin = self.root / "fake-tools"
        self.bin.mkdir()
        tool = '''import os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ["TEST_RELEASE_ROOT"])
if name == "hdiutil":
    if sys.argv[1] == "attach":
        mount = pathlib.Path(sys.argv[sys.argv.index("-mountpoint") + 1])
        shutil.copytree(root / "fixture/Linklet.app", mount / "Linklet.app")
    else:
        mount = pathlib.Path(sys.argv[2])
        shutil.rmtree(mount / "Linklet.app")
        (root / "detached").touch()
elif os.environ.get("TEST_FAIL_SIGNING"):
    sys.exit("Signing check rejected the fixture")
'''
        for name in ("codesign", "spctl", "xcrun", "hdiutil"):
            self.make_tool(name, tool)
        self.make_tool("generate_appcast", '''import os, pathlib, sys, xml.etree.ElementTree as ET
folder = pathlib.Path(sys.argv[-1])
# Source archives must never be presented as update candidates.
assert not list(folder.glob("*.tar.gz"))
dmg, = folder.glob("*.dmg")
prefix = sys.argv[sys.argv.index("--download-url-prefix") + 1]
ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
tree = ET.parse(folder / "appcast.xml")
item = ET.SubElement(tree.find("channel"), "item")
ET.SubElement(item, "{" + ns + "}version").text = "2"
attrs = {"url": prefix + dmg.name}
if not os.environ.get("TEST_UNSIGNED_FEED"):
    attrs["{" + ns + "}edSignature"] = "fixture-signature"
ET.SubElement(item, "enclosure", attrs)
tree.write(folder / "appcast.xml", encoding="utf-8", xml_declaration=True)
if os.environ.get("TEST_MODIFY_DMG"):
    dmg.write_bytes(b"changed after signing")
''')
        script = (ROOT / "scripts/prepare-sparkle-update.sh").read_text()
        for prefix, name in (("/usr/bin/", "codesign"), ("/usr/sbin/", "spctl"),
                             ("/usr/bin/", "xcrun"), ("/usr/bin/", "hdiutil")):
            script = script.replace(prefix + name, str(self.bin / name))
        self.script = self.root / "scripts/prepare-sparkle-update.sh"
        self.script.write_text(script)
        self.output = self.root / "build/sparkle/1.2.3-2"

    def make_tool(self, name, code):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + code)
        path.chmod(0o755)

    def run_script(self, **environment):
        return subprocess.run(
            ["bash", str(self.script), str(self.dmg), str(self.source), str(self.bin)],
            env={**os.environ, "TEST_RELEASE_ROOT": str(self.root), **environment},
            text=True, capture_output=True,
        )

    def test_only_two_assets_and_dmg_bytes_preserved(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        assets = self.output / "release"
        self.assertEqual(sorted(p.name for p in assets.iterdir()),
                         ["Linklet-1.2.3-source.tar.gz", "Linklet-1.2.3.dmg"])
        self.assertEqual((assets / "Linklet-1.2.3.dmg").read_bytes(), self.dmg.read_bytes())
        self.assertEqual((assets / "Linklet-1.2.3-source.tar.gz").read_bytes(), self.source.read_bytes())
        self.assertTrue((self.output / "feed/appcast.xml").exists())
        description = (self.output / "release-description.md").read_text()
        for path in (self.dmg, self.source):
            self.assertIn(hashlib.sha256(path.read_bytes()).hexdigest(), description)
        self.assertTrue((self.root / "detached").exists())

    def test_signing_rejection_stops_before_creating_assets(self):
        result = self.run_script(TEST_FAIL_SIGNING="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_wrong_public_key_stops_and_ejects_image(self):
        self.info["SUPublicEDKey"] = "wrong-key"
        (self.fixture / "Info.plist").write_bytes(plistlib.dumps(self.info))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Wrong app or Sparkle public key", result.stderr)
        self.assertTrue((self.root / "detached").exists())
        self.assertFalse(self.output.exists())

    def test_unsigned_feed_is_not_prepared_for_publication(self):
        result = self.run_script(TEST_UNSIGNED_FEED="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.output / "feed/appcast.xml").exists())

    def test_disabled_automatic_updates_stop_release(self):
        self.info["SUAutomaticallyUpdate"] = False
        (self.fixture / "Info.plist").write_bytes(plistlib.dumps(self.info))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Automatic Sparkle updates are not enabled", result.stderr)
        self.assertTrue((self.root / "detached").exists())
        self.assertFalse(self.output.exists())

    def test_modified_dmg_is_rejected(self):
        result = self.run_script(TEST_MODIFY_DMG="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.output / "feed/appcast.xml").exists())


if __name__ == "__main__":
    unittest.main()

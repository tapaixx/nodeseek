import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fork_release import package_archive, select_version, sha256, upstream_version, write_metadata


class ForkVersionTests(unittest.TestCase):
    def test_first_fork_build_ignores_upstream_tags(self):
        version = select_version("1.3.1", ["ios/v1.3.1", "ios/v1.3.1-build.20261111185129"], [])
        self.assertEqual(version, {
            "base_version": "1.3.1", "version": "1.3.1-1",
            "tag": "v1.3.1-1", "build_number": "1",
        })

    def test_sequence_sorts_numerically_and_ignores_other_versions(self):
        version = select_version("1.3.1", ["v1.3.1-9", "v1.3.1-10", "v1.3.2-99", "v1.3.1-beta.100"], [])
        self.assertEqual(version["version"], "1.3.1-11")

    def test_upstream_upgrade_starts_new_sequence(self):
        self.assertEqual(select_version("1.3.2", ["v1.3.1-10"], [])["version"], "1.3.2-1")

    def test_retry_uses_existing_version_for_same_commit(self):
        version = select_version("1.3.1", ["v1.3.1-4", "v1.3.1-5"], ["v1.3.1-4"])
        self.assertEqual(version["version"], "1.3.1-4")

    def test_inconsistent_project_versions_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary) / "project.pbxproj"
            project.write_text("MARKETING_VERSION = 1.3.1;\nMARKETING_VERSION = 1.3.2;")
            with self.assertRaisesRegex(ValueError, "same MARKETING_VERSION"):
                upstream_version(project)
            project.write_text("MARKETING_VERSION = 1.3.1;\nMARKETING_VERSION = 1.3.1;")
            self.assertEqual(upstream_version(project), "1.3.1")

    def test_metadata_keeps_numeric_system_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            info = Path(temporary) / "Info.plist"
            info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.3.1", "CFBundleDisplayName": "NS Connect"}))
            with patch.dict(os.environ, {
                "GITHUB_SHA": "abc123", "GITHUB_REPOSITORY": "owner/nodeseek", "GITHUB_RUN_ID": "42",
            }, clear=True):
                write_metadata(info, "1.3.1-2")
            result = plistlib.loads(info.read_bytes())
            self.assertEqual(result["CFBundleShortVersionString"], "1.3.1")
            self.assertEqual(result["Build Release Version"], "1.3.1-2")
            self.assertEqual(result["Build Git SHA"], "abc123")
            self.assertEqual(result["Build GitHub Run URL"], "https://github.com/owner/nodeseek/actions/runs/42")


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "App.xcarchive"
        self.app = self.archive / "Products/Applications/nodeseek.app"
        self.app.mkdir(parents=True)
        self.output = self.root / "release"
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "1.3.1", "CFBundleVersion": "2",
            "Build Release Version": "1.3.1-2",
        }))
        executable = self.app / "nodeseek"
        executable.write_bytes(b"fake executable")
        executable.chmod(0o755)

    def test_packages_installable_layout_permissions_symlinks_and_checksums(self):
        (self.app / "alias").symlink_to("nodeseek")
        ipa = package_archive(self.archive, self.output, "1.3.1-2")
        self.assertEqual(ipa.name, "NS-Connect-1.3.1-2-unsigned.ipa")
        with zipfile.ZipFile(ipa) as archive:
            self.assertEqual(archive.read("Payload/nodeseek.app/nodeseek"), b"fake executable")
            executable = archive.getinfo("Payload/nodeseek.app/nodeseek")
            self.assertEqual((executable.external_attr >> 16) & 0o777, 0o755)
            link = archive.getinfo("Payload/nodeseek.app/alias")
            self.assertTrue(stat.S_ISLNK(link.external_attr >> 16))
            self.assertEqual(archive.read(link), b"nodeseek")
        provenance = json.loads((self.output / "build-provenance.json").read_text())
        self.assertEqual(provenance["version"], "1.3.1-2")
        self.assertEqual(provenance["ipa_sha256"], sha256(ipa))
        self.assertFalse(provenance["signed"])
        for line in (self.output / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ")
            self.assertEqual(digest, sha256(self.output / name))

    def test_rejects_extension_with_different_build_number(self):
        extension = self.app / "PlugIns/ProbeWidget.appex"
        extension.mkdir(parents=True)
        (extension / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "1.3.1", "CFBundleVersion": "1",
        }))
        with self.assertRaisesRegex(ValueError, "matching release versions"):
            package_archive(self.archive, self.output, "1.3.1-2")

    def test_rejects_missing_fork_display_version(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "1.3.1", "CFBundleVersion": "2",
        }))
        with self.assertRaisesRegex(ValueError, "display version"):
            package_archive(self.archive, self.output, "1.3.1-2")

    def test_rejects_signed_or_provisioned_bundle(self):
        (self.app / "embedded.mobileprovision").write_bytes(b"profile")
        with self.assertRaisesRegex(ValueError, "unsigned archive"):
            package_archive(self.archive, self.output, "1.3.1-2")

    def test_rejects_missing_app(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            package_archive(self.root / "missing", self.output, "1.3.1-2")


if __name__ == "__main__":
    unittest.main()

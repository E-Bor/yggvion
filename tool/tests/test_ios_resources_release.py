"""Check relocation before signing and the archive boundary before upload."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tool.ios_server_scripts import SCRIPTS, stage_scripts, verify_scripts


class IOSResourcesTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="yggvion ios resources ")
        self.addCleanup(directory.cleanup)
        self.app = Path(directory.name) / "Runner.app"
        self.framework = self.app / "Frameworks/App.framework"
        self.source = self.framework / "flutter_assets/assets/server"
        self.source.mkdir(parents=True)
        self.scripts = {
            "install.sh": '#!/bin/sh\nprintf "%s\\n" "Привет $HOME"\n'.encode(),
            "uninstall.sh": b"#!/bin/sh\n# uninstall\nexit 0\n",
        }
        for name, content in self.scripts.items():
            path = self.source / name
            path.write_bytes(content)
            path.chmod(0o755)

    def test_moves_unchanged_bytes_and_resigns_after_framework_changes(self):
        binary = self.source / "yggvion-linux-arm64"
        binary.write_bytes(b"server binary")
        manifest = self.source / "manifest.json"
        manifest.write_bytes(b'{"fixture": true}')

        def codesign(command, *, check):
            self.assertTrue(check)
            self.assertEqual(command, ["codesign", "--force", "--sign", "TEST-IDENTITY",
                                       str(self.framework / "App")])
            verify_scripts(self.app)
            for name, content in self.scripts.items():
                self.assertEqual((self.app / "ServerInstaller" / name).read_bytes(), content)
            self.assertEqual(binary.read_bytes(), b"server binary")
            self.assertEqual(manifest.read_bytes(), b'{"fixture": true}')

        with patch("tool.ios_server_scripts.subprocess.run", side_effect=codesign) as sign:
            stage_scripts(self.framework, self.app, identity="TEST-IDENTITY", configuration="Release")
            sign.assert_called_once()
            # An incremental invocation must not remove the relocated resources.
            stage_scripts(self.framework, self.app)
            sign.assert_called_once()
        verify_scripts(self.app)

    def test_local_unsigned_build_uses_adhoc_identity(self):
        with patch("tool.ios_server_scripts.subprocess.run") as sign:
            stage_scripts(self.framework, self.app, identity="")
        self.assertEqual(sign.call_args.args[0], ["codesign", "--force", "--sign", "-",
                                                 "--timestamp=none", str(self.framework / "App")])

    def test_signing_error_stops_build(self):
        with patch("tool.ios_server_scripts.subprocess.run",
                   side_effect=subprocess.CalledProcessError(1, "codesign")):
            with self.assertRaises(subprocess.CalledProcessError):
                stage_scripts(self.framework, self.app)

    def test_incomplete_pair_fails_without_mutating_resources(self):
        (self.source / "uninstall.sh").unlink()
        with patch("tool.ios_server_scripts.subprocess.run") as sign:
            with self.assertRaises(FileNotFoundError):
                stage_scripts(self.framework, self.app)
            sign.assert_not_called()
        self.assertEqual((self.source / "install.sh").read_bytes(), self.scripts["install.sh"])
        self.assertFalse((self.app / "ServerInstaller").exists())

    def test_local_build_without_payloads_is_allowed_but_archive_is_rejected(self):
        for name in SCRIPTS:
            (self.source / name).unlink()
        with patch("tool.ios_server_scripts.subprocess.run") as sign:
            stage_scripts(self.framework, self.app)
            sign.assert_not_called()
        with self.assertRaisesRegex(ValueError, "Missing iOS app resource"):
            verify_scripts(self.app)

    def test_archive_rejects_executable_empty_or_misplaced_scripts(self):
        with patch("tool.ios_server_scripts.subprocess.run"):
            stage_scripts(self.framework, self.app)
        for name in SCRIPTS:
            with self.subTest(name=name):
                resource = self.app / "ServerInstaller" / name
                resource.chmod(0o755)
                with self.assertRaisesRegex(ValueError, "non-executable"):
                    verify_scripts(self.app)
                resource.chmod(0o644)
                resource.write_bytes(b"")
                with self.assertRaisesRegex(ValueError, "Missing iOS app resource"):
                    verify_scripts(self.app)
                resource.write_bytes(self.scripts[name])
                (self.source / name).write_bytes(self.scripts[name])
                with self.assertRaisesRegex(ValueError, "still inside App.framework"):
                    verify_scripts(self.app)
                (self.source / name).unlink()
        verify_scripts(self.app)


if __name__ == "__main__":
    unittest.main()

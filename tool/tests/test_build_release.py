import base64
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tool.ci import build_release as release


class AndroidReleaseTest(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="yggvion android release ")
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.output = self.root / "installer.apk"
        self.key = self.root / "yggvion-release.jks"
        self.env = {
            "ANDROID_KEYSTORE_BASE64": base64.b64encode(b"fixture-keystore").decode(),
            "ANDROID_KEYSTORE_PASSWORD": "fixture-password", "ANDROID_KEY_ALIAS": "fixture-alias",
            "ANDROID_KEY_PASSWORD": "fixture-key-password", "RUNNER_TEMP": str(self.root),
            "ANDROID_HOME": str(self.root / "sdk"),
        }

    def test_missing_or_invalid_credentials_fail_without_creating_key(self):
        for value in ("", "invalid-base64!"):
            env = {**self.env, "ANDROID_KEYSTORE_BASE64": value}
            with self.subTest(value=value), self.assertRaises(ValueError) as result:
                release.android_keystore(env, self.key)
            self.assertNotIn("invalid-base64!", str(result.exception))
            self.assertFalse(self.key.exists())

    def test_existing_key_is_never_overwritten(self):
        self.key.write_bytes(b"existing")
        with self.assertRaises(FileExistsError):
            release.build_android(self.root, self.output, "1.2.3+4", self.env)
        self.assertEqual(self.key.read_bytes(), b"existing")

    def test_build_failure_removes_private_key_and_does_not_export(self):
        with patch.object(release, "run", side_effect=subprocess.CalledProcessError(1, ["flutter"])):
            with self.assertRaises(subprocess.CalledProcessError):
                release.build_android(self.root, self.output, "1.2.3+4", self.env)
        self.assertFalse(self.key.exists())
        self.assertFalse(self.output.exists())

    def test_apk_is_exported_only_after_signature_verification(self):
        signer = self.root / "sdk/build-tools/36.0.0/apksigner"
        signer.parent.mkdir(parents=True)
        signer.write_text("fixture")
        apk = self.root / "build/app/outputs/flutter-apk/app-release.apk"
        apk.parent.mkdir(parents=True)
        calls = []

        def command(args, **kwargs):
            calls.append(args)
            if args[0] == "flutter":
                self.assertEqual(kwargs["env"]["ANDROID_KEYSTORE_PATH"], str(self.key))
                self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
                apk.write_bytes(b"signed-fixture")
            else:
                self.assertEqual(args, [signer, "verify", apk])
                self.assertFalse(self.output.exists())

        with patch.object(release, "run", side_effect=command):
            release.build_android(self.root, self.output, "1.2.3+4", self.env)
        self.assertEqual(self.output.read_bytes(), b"signed-fixture")
        self.assertFalse(self.key.exists())
        self.assertIn("--build-number=4", calls[0])


class DesktopPackageTest(unittest.TestCase):
    def test_windows_installer_gets_the_latest_complete_native_runtime(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            bundle = root / "bundle"
            bundle.mkdir()
            for version in ("14.9.0", "14.10.0", "15.0.0"):
                runtime = root / "redist" / version / "x64/Microsoft.VC143.CRT"
                runtime.mkdir(parents=True)
                for name in ("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"):
                    if version != "15.0.0" or name != "vcruntime140_1.dll":
                        (runtime / name).write_text(version)
            release.stage_windows_runtime(bundle, root / "redist")
            for name in ("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"):
                self.assertEqual((bundle / name).read_text(), "14.10.0")

    def test_missing_windows_runtime_fails_instead_of_packaging_a_broken_installer(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValueError, "redistributable"):
                release.stage_windows_runtime(Path(folder), Path(folder) / "missing")

    def test_deb_contains_native_libraries_assets_and_desktop_uri_handler(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            bundle = root / "bundle"
            (bundle / "lib").mkdir(parents=True)
            (bundle / "data/flutter_assets").mkdir(parents=True)
            (bundle / "yggvion").write_bytes(b"fixture")
            (bundle / "lib/native.so").write_bytes(b"native-fixture")
            (bundle / "data/flutter_assets/payload").write_bytes(b"server-fixture")
            icon = root / "icon.png"
            icon.write_bytes(b"fixture-image")
            stage = root / "package"
            release.stage_deb(bundle, stage, icon, "0.1.0+7")
            self.assertEqual((stage / "opt/yggvion/lib/native.so").read_bytes(), b"native-fixture")
            self.assertEqual((stage / "opt/yggvion/data/flutter_assets/payload").read_bytes(), b"server-fixture")
            self.assertEqual((stage / "opt/yggvion/yggvion").stat().st_mode & 0o777, 0o755)
            self.assertEqual((stage / "usr/bin/yggvion").readlink(), Path("/opt/yggvion/yggvion"))
            self.assertIn("Version: 0.1.0+7", (stage / "DEBIAN/control").read_text())
            desktop = (stage / "usr/share/applications/yggvion.desktop").read_text()
            self.assertIn("Exec=/usr/bin/yggvion %u", desktop)
            self.assertIn("x-scheme-handler/yggvion", desktop)


if __name__ == "__main__":
    unittest.main()

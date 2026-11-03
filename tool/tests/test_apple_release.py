"""Exercise Apple release failure boundaries without accounts or real keychains."""
import base64
import contextlib
import copy
import datetime as dt
import hashlib
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tool.ci import apple_release as release


TEAM = "TEAM123456"
CERTIFICATE = b"fixture-der-certificate"
IDENTITY = hashlib.sha1(CERTIFICATE).hexdigest().upper()
UUID = "11111111-2222-3333-4444-555555555555"
WIDGET_UUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


def profile(bundle_id=release.BUNDLE_ID, uuid=UUID):
    return {
        "UUID": uuid, "TeamIdentifier": [TEAM], "ApplicationIdentifierPrefix": [TEAM],
        "ExpirationDate": dt.datetime(2099, 1, 1), "DeveloperCertificates": [CERTIFICATE],
        "Entitlements": {"application-identifier": f"{TEAM}.{bundle_id}",
                         "com.apple.developer.team-identifier": TEAM,
                         "get-task-allow": False, "beta-reports-active": True},
    }


def environment():
    env = {"APPLE_TEAM_ID": TEAM, "APP_STORE_CONNECT_KEY_ID": "AB12345678",
           "APP_STORE_CONNECT_ISSUER_ID": UUID}
    for prefix in ("IOS_DISTRIBUTION", "MACOS_DEVELOPER_ID"):
        env[f"{prefix}_P12_BASE64"] = base64.b64encode(b"p12-fixture").decode()
        env[f"{prefix}_P12_PASSWORD"] = "private-password-never-log"
    env["APP_STORE_CONNECT_PRIVATE_KEY_BASE64"] = base64.b64encode(b"p8-fixture").decode()
    env["IOS_PROVISIONING_PROFILE_BASE64"] = base64.b64encode(b"profile-fixture").decode()
    env["IOS_WIDGET_PROVISIONING_PROFILE_BASE64"] = base64.b64encode(b"widget-profile-fixture").decode()
    return env


class AppleReleaseValidationTest(unittest.TestCase):
    def test_profile_rejects_wrong_app_team_type_expiration_and_certificate(self):
        self.assertEqual(release.validate_profile(profile(), TEAM, IDENTITY), UUID)
        invalid = []
        for key, value in (("ProvisionedDevices", []), ("ProvisionsAllDevices", True),
                           ("ExpirationDate", dt.datetime(2000, 1, 1)),
                           ("DeveloperCertificates", [b"other-cert"]),
                           ("TeamIdentifier", ["OTHERTEAM1"]), ("UUID", "../../unsafe")):
            data = profile()
            data[key] = value
            invalid.append(data)
        for key, value in (("application-identifier", f"{TEAM}.*"),
                           ("application-identifier", f"{TEAM}.dev.example.wrongapp"),
                           ("get-task-allow", True)):
            data = profile()
            data["Entitlements"][key] = value
            invalid.append(data)
        for data in invalid:
            with self.subTest(data=data), self.assertRaises(release.ReleaseError):
                release.validate_profile(data, TEAM, IDENTITY)

    def test_certificate_prefix_team_and_private_identity_are_required(self):
        valid = f'1) {IDENTITY} "Apple Distribution: Example ({TEAM})"'
        self.assertEqual(release.select_identity(valid, "ios", TEAM), IDENTITY)
        for output, platform in ((valid, "macos"), (valid + "\n" + valid, "ios"),
                                 (valid.replace(TEAM, "OTHERT1234"), "ios"),
                                 ("0 valid identities found", "ios")):
            with self.subTest(output=output), self.assertRaises(release.ReleaseError):
                release.select_identity(output, platform, TEAM)

    def test_missing_or_invalid_secrets_report_names_without_values(self):
        env = environment()
        self.assertEqual(release.validate_secrets(env, "ios"), "IOS_DISTRIBUTION")
        del env["IOS_DISTRIBUTION_P12_PASSWORD"]
        with self.assertRaisesRegex(release.ReleaseError, "IOS_DISTRIBUTION_P12_PASSWORD"):
            release.validate_secrets(env, "ios")
        env["BROKEN"] = "not-base64-private-content"
        with self.assertRaises(release.ReleaseError) as error:
            release.decode_secret(env, "BROKEN")
        self.assertNotIn(env["BROKEN"], str(error.exception))

    def test_subprocess_errors_do_not_echo_passwords(self):
        result = subprocess.CompletedProcess([], 1, b"private-output", b"private-error")
        log = io.StringIO()
        with patch.object(release.subprocess, "run", return_value=result), contextlib.redirect_stdout(log):
            with self.assertRaises(release.ReleaseError) as error:
                release.run(["security", "import", "-P", "private-password"], label="import key", capture=True)
        self.assertNotIn("private", log.getvalue() + str(error.exception))

    def test_export_preserves_tag_build_and_never_requests_review(self):
        profiles = {release.BUNDLE_ID: UUID, release.WIDGET_BUNDLE_ID: WIDGET_UUID}
        for upload in (False, True):
            options = release.export_options(TEAM, IDENTITY, profiles, upload=upload)
            self.assertFalse(options["manageAppVersionAndBuildNumber"])
            self.assertEqual(options["provisioningProfiles"], profiles)
            self.assertEqual(options["destination"], "upload" if upload else "export")
            self.assertEqual(options["method"], "app-store-connect")
            self.assertNotIn("testFlightInternalTestingOnly", options)

    def test_widget_needs_its_own_app_store_profile(self):
        data = profile(release.WIDGET_BUNDLE_ID, WIDGET_UUID)
        self.assertEqual(release.validate_profile(data, TEAM, IDENTITY,
                                                bundle_id=release.WIDGET_BUNDLE_ID), WIDGET_UUID)
        with self.assertRaises(release.ReleaseError):
            release.validate_profile(profile(), TEAM, IDENTITY, bundle_id=release.WIDGET_BUNDLE_ID)
        with self.assertRaises(release.ReleaseError):
            release.validate_profile(data, TEAM, IDENTITY)
        env = environment()
        del env["IOS_WIDGET_PROVISIONING_PROFILE_BASE64"]
        with self.assertRaisesRegex(release.ReleaseError, "IOS_WIDGET_PROVISIONING_PROFILE_BASE64"):
            release.validate_secrets(env, "ios")

    def test_old_tag_formats_are_rejected(self):
        for version in ("v2.0.0.2", "v2.0.0+2", "2.0.0.2", "2.0.0", "2.0.0+0"):
            with self.subTest(version=version), self.assertRaises(release.ReleaseError):
                release.AppleRelease("ios", version, Path("unused"))


class AppleReleaseFlowTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="yggvion apple release ")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.project = self.root / "client/ios/Runner.xcodeproj/project.pbxproj"
        self.project.parent.mkdir(parents=True)
        self.project.write_bytes(b"original-project")
        self.saved_profile = self.home / f"Library/MobileDevice/Provisioning Profiles/{UUID}.mobileprovision"
        self.saved_profile.parent.mkdir(parents=True)
        self.saved_profile.write_bytes(b"original-profile")
        self.calls = []
        self.exports = []
        self.fail_label = None
        self.notary_status = "Accepted"
        self.notary_exit_error = False
        self.widget_version = "2.3.4"
        self.include_widget = True
        self.context = release.AppleRelease("ios", "2.3.4+56", self.root / "state", root=self.root, env=environment())
        mock_run = patch.object(release, "run", side_effect=self.fake_run)
        mock_home = patch.object(release.Path, "home", return_value=self.home)
        mock_run.start()
        mock_home.start()
        self.addCleanup(mock_run.stop)
        self.addCleanup(mock_home.stop)

    def fake_run(self, command, *, label, **kwargs):
        args = [str(arg) for arg in command]
        self.calls.append((label, args))
        if label == self.fail_label:
            raise release.ReleaseError("simulated command failure")
        ctx = self.context
        if label == "read keychain search list":
            return b'"/original/login.keychain-db"\n"/original/other.keychain-db"'
        if label == "create temporary keychain":
            ctx.keychain.write_bytes(b"keychain-fixture")
        elif label == "delete temporary keychain":
            ctx.keychain.unlink()
        elif label == "validate signing identity":
            prefix = "Apple Distribution" if ctx.platform == "ios" else "Developer ID Application"
            return f'1) {IDENTITY} "{prefix}: Fixture ({TEAM})"'.encode()
        elif label == "read Runner distribution profile":
            return plistlib.dumps(profile())
        elif label == "read TrackingWidget distribution profile":
            return plistlib.dumps(profile(release.WIDGET_BUNDLE_ID, WIDGET_UUID))
        elif label == "configure app and widget Release signing":
            self.project.write_bytes(b"ci-modified-project")
        elif label in ("archive signed iOS app", "build macOS application"):
            if ctx.platform == "ios":
                app = ctx.build / "Yggvion.xcarchive/Products/Applications/Runner.app"
            else:
                app = ctx.build / "DerivedData/Build/Products/Release/Yggvion.app/Contents"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": release.BUNDLE_ID, "CFBundleShortVersionString": "2.3.4",
                "CFBundleVersion": "56"}))
            if ctx.platform == "ios":
                resources = app / "ServerInstaller"
                resources.mkdir()
                for name in ("install.sh", "uninstall.sh"):
                    (resources / name).write_bytes(b"#!/bin/sh\nexit 0\n")
                    (resources / name).chmod(0o644)
            if ctx.platform == "ios" and self.include_widget:
                widget = app / "PlugIns/TrackingWidget.appex"
                widget.mkdir(parents=True)
                (widget / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": release.WIDGET_BUNDLE_ID,
                    "CFBundleShortVersionString": self.widget_version, "CFBundleVersion": "56"}))
        elif label in ("export signed App Store IPA", "upload build and symbols to App Store Connect"):
            self.exports.append(plistlib.loads(Path(args[args.index("-exportOptionsPlist") + 1]).read_bytes()))
            path = Path(args[args.index("-exportPath") + 1])
            path.mkdir()
            if label == "export signed App Store IPA":
                (path / "Yggvion.ipa").write_bytes(b"ipa-fixture")
        elif label == "create DMG":
            Path(args[-1]).write_bytes(b"dmg-fixture")
        elif label == "submit DMG to Apple notarization":
            response = json.dumps({"status": self.notary_status, "id": UUID}).encode()
            if self.notary_exit_error:
                raise release.ReleaseError("notarytool exit 65", output=response)
            return response
        elif label == "download notarization rejection details":
            return b'{"issues": [{"message": "invalid nested signature"}]}'
        return b""

    def assert_cleaned(self):
        self.assertFalse(self.context.state_dir.exists())
        self.assertEqual(self.project.read_bytes(), b"original-project")
        self.assertEqual(self.saved_profile.read_bytes(), b"original-profile")
        self.assertFalse((self.home / f"Library/Developer/Xcode/UserData/Provisioning Profiles/{UUID}.mobileprovision").exists())
        for location in ("Library/MobileDevice/Provisioning Profiles",
                         "Library/Developer/Xcode/UserData/Provisioning Profiles"):
            self.assertFalse((self.home / location / f"{WIDGET_UUID}.mobileprovision").exists())
        cleanup_args = next(args for label, args in self.calls if label == "restore keychain search list")
        self.assertEqual(cleanup_args[-2:], ["/original/login.keychain-db", "/original/other.keychain-db"])

    def test_ios_archive_export_upload_and_cleanup(self):
        self.context.execute(upload=True)
        self.assertEqual(self.context.output.read_bytes(), b"ipa-fixture")
        self.assertEqual([o["destination"] for o in self.exports], ["export", "upload"])
        self.assertTrue(all(not o["manageAppVersionAndBuildNumber"] for o in self.exports))
        self.assertTrue(all(o["provisioningProfiles"] == {
            release.BUNDLE_ID: UUID, release.WIDGET_BUNDLE_ID: WIDGET_UUID,
        } for o in self.exports))
        archive = next(args for label, args in self.calls if label == "archive signed iOS app")
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", archive)
        self.assertFalse(any("PROVISIONING_PROFILE_SPECIFIER=" in arg for arg in archive))
        flutter = next(args for label, args in self.calls if label == "prepare Flutter and CocoaPods configuration")
        self.assertIn("--build-name=2.3.4", flutter)
        self.assertIn("--build-number=56", flutter)
        self.assert_cleaned()

    def test_manual_branch_export_does_not_upload(self):
        self.context.execute(upload=False)
        self.assertEqual([o["destination"] for o in self.exports], ["export"])
        self.assert_cleaned()

    def test_invalid_ios_resources_stop_before_export_and_cleanup_signing(self):
        with patch.object(release, "verify_scripts", side_effect=ValueError("Invalid app resources")):
            with self.assertRaisesRegex(ValueError, "Invalid app resources"):
                self.context.execute(upload=True)
        self.assertEqual(self.exports, [])
        self.assertFalse(self.context.output.exists())
        self.assert_cleaned()

    def test_missing_or_mismatched_widget_fails_before_upload(self):
        for include, version in ((False, "2.3.4"), (True, "9.9.9")):
            self.include_widget, self.widget_version = include, version
            self.calls.clear()
            with self.subTest(include=include, version=version), self.assertRaises(release.ReleaseError):
                self.context.execute(upload=True)
            self.assertNotIn("upload build and symbols to App Store Connect", [label for label, _ in self.calls])
            self.assertFalse(self.context.output.exists())
            self.assert_cleaned()

    def test_build_or_upload_failure_restores_files_and_never_publishes_ipa(self):
        for label in ("archive signed iOS app", "upload build and symbols to App Store Connect"):
            self.fail_label = label
            self.calls.clear()
            with self.subTest(label=label), self.assertRaises(release.ReleaseError):
                self.context.execute(upload=True)
            self.assertFalse(self.context.output.exists())
            self.assert_cleaned()

    def test_failed_key_import_still_deletes_keychain_and_private_files(self):
        self.fail_label = "import signing certificate and private key"
        with self.assertRaises(release.ReleaseError):
            self.context.execute()
        self.assert_cleaned()

    def test_missing_secret_fails_before_creating_keychain(self):
        del self.context.env["IOS_DISTRIBUTION_P12_BASE64"]
        with self.assertRaises(release.ReleaseError):
            self.context.execute()
        self.assertEqual(self.calls, [])
        self.assertFalse(self.context.state_dir.exists())

    def test_accepted_notarization_staples_verifies_then_exports_dmg(self):
        self.context.platform = "macos"
        self.context.output = self.context.output.with_name("yggvion.dmg")
        self.context.execute()
        labels = [label for label, _ in self.calls]
        checks = ["sign DMG", "submit DMG to Apple notarization", "staple notarization ticket",
                  "validate stapled ticket", "verify Gatekeeper accepts the DMG"]
        self.assertEqual([label for label in labels if label in checks], checks)
        self.assertEqual(self.context.output.read_bytes(), b"dmg-fixture")
        self.assert_cleaned()

    def test_rejected_or_pending_notarization_never_staples_or_exports(self):
        self.context.platform = "macos"
        self.context.output = self.context.output.with_name("yggvion.dmg")
        for status in ("Invalid", "In Progress"):
            self.notary_status = status
            self.notary_exit_error = True
            self.calls.clear()
            with self.subTest(status=status), self.assertRaisesRegex(release.ReleaseError, "not Accepted"):
                self.context.execute()
            self.assertFalse(self.context.output.exists())
            self.assertNotIn("staple notarization ticket", [label for label, _ in self.calls])
            self.assertTrue((self.context.build / "notarization-log.json").exists())
            self.assert_cleaned()

    def test_signing_finds_native_assets_and_versioned_frameworks_inside_out(self):
        app = self.root / "Yggvion.app"
        framework = app / "Contents/Frameworks/Native.framework"
        native = framework / "Versions/A/Native"
        native.parent.mkdir(parents=True)
        native.write_bytes(bytes.fromhex("cffaedfe") + b"fixture")
        native.chmod(0o644)  # A Dart native asset need not have the executable bit.
        (framework / "Versions/Current").symlink_to("A")
        (framework / "Native").symlink_to("Versions/Current/Native")
        resource = framework / "resource.json"
        resource.write_text("{}")
        targets = release.signing_targets(app)
        self.assertEqual(targets, [native, framework, app])


class IOSSigningProjectTest(unittest.TestCase):
    def test_only_app_and_widget_release_signing_changes(self):
        ruby = shutil.which("ruby")
        if not ruby or subprocess.run([ruby, "-rxcodeproj", "-e", ""], capture_output=True).returncode:
            self.skipTest("Ruby xcodeproj required (installed by CocoaPods in Apple CI)")
        with tempfile.TemporaryDirectory(prefix="yggvion signing project ") as folder:
            project = Path(folder) / "Runner.xcodeproj"
            shutil.copytree(release.ROOT / "client/ios/Runner.xcodeproj", project)
            inspect = '''require 'xcodeproj'; require 'json'
p = Xcodeproj::Project.open(ARGV[0])
puts JSON.generate(p.targets.to_h { |t| [t.name, t.build_configurations.to_h { |c| [c.name, c.build_settings] }] })
'''
            def settings():
                return json.loads(subprocess.check_output([ruby, "-e", inspect, str(project)]))
            before = settings()
            subprocess.run([ruby, str(release.ROOT / "tool/ci/configure_ios_signing.rb"),
                            str(project), TEAM, IDENTITY, UUID, WIDGET_UUID], check=True, capture_output=True)
            after = settings()
            expected = copy.deepcopy(before)
            expected["Runner"]["Release"] = after["Runner"]["Release"]
            expected["TrackingWidget"]["Release"] = after["TrackingWidget"]["Release"]
            self.assertEqual(expected, after)  # Debug/Profile and test targets stay intact.
            config = after["Runner"]["Release"]
            self.assertEqual(config["CODE_SIGN_IDENTITY[sdk=iphoneos*]"], IDENTITY)
            self.assertEqual(config["CODE_SIGN_STYLE"], "Manual")
            self.assertEqual(config["PROVISIONING_PROFILE_SPECIFIER"], UUID)
            self.assertEqual(config["PRODUCT_BUNDLE_IDENTIFIER"], release.BUNDLE_ID)
            widget = after["TrackingWidget"]["Release"]
            self.assertEqual(widget["PROVISIONING_PROFILE_SPECIFIER"], WIDGET_UUID)
            self.assertEqual(widget["PRODUCT_BUNDLE_IDENTIFIER"], release.WIDGET_BUNDLE_ID)
            self.assertEqual(widget["CODE_SIGN_STYLE"], "Manual")
            self.assertEqual(widget["DEVELOPMENT_TEAM"], TEAM)


if __name__ == "__main__":
    unittest.main()

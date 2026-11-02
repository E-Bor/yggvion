#!/usr/bin/env python3
"""Signed Apple releases on disposable macOS CI runners (Python stdlib only).

Credentials live in RUNNER_TEMP, never in the repository or release artifacts.
The same cleanup runs in finally and in the workflow's always() step.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tool.ci.release_version import parse_version

BUNDLE_ID = "dev.yggvion.yggvion"
WIDGET_BUNDLE_ID = BUNDLE_ID + ".Tracking"
ROOT = Path(__file__).resolve().parents[2]
MACHO_MAGICS = {
    bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}


class ReleaseError(Exception):
    def __init__(self, message, *, output=b""):
        super().__init__(message)
        self.output = output


def run(args, *, label, capture=False, timeout=120):
    # Never print argv: security import / set-key-partition-list contain passwords.
    print(f"Apple release: {label}", flush=True)
    try:
        result = subprocess.run(
            [str(arg) for arg in args], check=False, timeout=timeout,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
    except subprocess.TimeoutExpired:
        raise ReleaseError(f"{label}: timed out after {timeout}s") from None
    if result.returncode:
        raise ReleaseError(f"{label}: exit code {result.returncode}", output=result.stdout or b"")
    return result.stdout if capture else b""


def decode_secret(env, name):
    try:
        result = base64.b64decode("".join(env[name].split()), validate=True)
    except (ValueError, KeyError):
        raise ReleaseError(f"{name}: expected Base64-encoded file") from None
    if not result:
        raise ReleaseError(f"{name}: file is empty")
    return result


def validate_secrets(env, platform):
    common = ("APPLE_TEAM_ID", "APP_STORE_CONNECT_KEY_ID",
              "APP_STORE_CONNECT_ISSUER_ID", "APP_STORE_CONNECT_PRIVATE_KEY_BASE64")
    prefix = "IOS_DISTRIBUTION" if platform == "ios" else "MACOS_DEVELOPER_ID"
    required = (*common, f"{prefix}_P12_BASE64", f"{prefix}_P12_PASSWORD")
    if platform == "ios":
        required += ("IOS_PROVISIONING_PROFILE_BASE64", "IOS_WIDGET_PROVISIONING_PROFILE_BASE64")
    missing = [key for key in required if not env.get(key, "").strip()]
    if missing:
        raise ReleaseError("Missing GitHub Secrets: " + ", ".join(missing))
    for key in ("APPLE_TEAM_ID", "APP_STORE_CONNECT_KEY_ID"):
        if not re.fullmatch(r"[A-Z0-9]{10}", env[key]):
            raise ReleaseError(f"{key}: expected a 10-character Apple identifier")
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}",
                        env["APP_STORE_CONNECT_ISSUER_ID"]):
        raise ReleaseError("APP_STORE_CONNECT_ISSUER_ID: expected a UUID from Team Keys")
    return prefix


def validate_profile(profile, team, identity, now=None, *, bundle_id=BUNDLE_ID):
    """Reject development/ad-hoc, wrong app/team/certificate and expired profiles."""
    entitlements = profile.get("Entitlements", {})
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    app_id = entitlements.get("application-identifier")
    if (team not in profile.get("TeamIdentifier", [])
            or entitlements.get("com.apple.developer.team-identifier") != team
            or app_id not in [f"{prefix}.{bundle_id}" for prefix in prefixes]):
        raise ReleaseError(f"Provisioning profile must belong to the configured team / {bundle_id}")
    if ("ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices")
            or entitlements.get("get-task-allow")):
        raise ReleaseError("Expected an App Store Connect distribution profile")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, dt.datetime) or expires.replace(tzinfo=dt.timezone.utc) <= (
            now or dt.datetime.now(dt.timezone.utc)):
        raise ReleaseError("Provisioning profile is expired or has no expiration date")
    hashes = [hashlib.sha1(cert).hexdigest().upper()
              for cert in profile.get("DeveloperCertificates", [])]
    if identity.upper() not in hashes:
        raise ReleaseError("Provisioning profile does not include the imported Apple Distribution certificate")
    uuid = profile.get("UUID", "")
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", uuid):
        raise ReleaseError("Provisioning profile has an invalid UUID")
    return uuid


def select_identity(output, platform, team):
    prefix = "Apple Distribution:" if platform == "ios" else "Developer ID Application:"
    matches = [digest for digest, name in re.findall(r'([A-Fa-f0-9]{40}) "([^"]+)"', output)
               if name.startswith(prefix) and name.endswith(f"({team})")]
    if len(matches) != 1:
        raise ReleaseError(f"P12 must contain exactly one valid {prefix} identity for {team}, with its private key")
    return matches[0].upper()


def export_options(team, identity, profiles, *, upload=False):
    return {
        "method": "app-store-connect", "destination": "upload" if upload else "export",
        "teamID": team, "signingStyle": "manual", "signingCertificate": identity,
        "provisioningProfiles": profiles,
        "manageAppVersionAndBuildNumber": False,
        "uploadSymbols": True, "stripSwiftSymbols": True,
    }


def signing_targets(app):
    """Inside out: Mach-O files, their framework/helper containers, then the app.

    rglob does not descend symlink directories. Avoid signing versioned framework
    aliases twice, and include Dart native assets even without an executable bit.
    """
    targets = []
    for path in app.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in (".framework", ".app", ".xpc", ".appex", ".bundle"):
            # Resource-only bundles have no executable and need no code signature.
            if path.suffix != ".bundle" or any(
                    (path / name).exists() for name in ("Contents/MacOS", "MacOS")):
                targets.append(path)
        elif path.is_file():
            with path.open("rb") as binary:
                if binary.read(4) in MACHO_MAGICS:
                    targets.append(path)
    return sorted(targets, key=lambda p: (-len(p.parts), str(p))) + [app]


def cleanup(state_dir):
    state_file = state_dir / "state.json"
    if not state_file.exists():
        return
    state = json.loads(state_file.read_text())
    failures = []
    # Attempt every cleanup even if another one fails. Keep backups for a retry.
    for item in reversed(state.get("restores", [])):
        try:
            target = Path(item["target"])
            if item["backup"]:
                shutil.copy2(item["backup"], target)
            else:
                target.unlink(missing_ok=True)
        except OSError:
            failures.append("restore a temporary signing file")
    original_search = state.get("keychain_search")
    if original_search is not None:
        try:
            run(["security", "list-keychains", "-d", "user", "-s", *original_search],
                label="restore keychain search list", capture=True)
        except ReleaseError:
            failures.append("restore keychain search list")
    keychain = state_dir / "signing.keychain-db"
    if keychain.exists():
        try:
            run(["security", "delete-keychain", keychain], label="delete temporary keychain", capture=True)
        except ReleaseError:
            failures.append("delete temporary keychain")
    # Delete private keys even if a system cleanup failed; retain only backups/state.
    for name in ("certificate.p12", "AuthKey.p8", "Runner.mobileprovision", "TrackingWidget.mobileprovision"):
        (state_dir / name).unlink(missing_ok=True)
    if failures:
        raise ReleaseError("Cleanup failed: " + ", ".join(failures))
    shutil.rmtree(state_dir)


class AppleRelease:
    def __init__(self, platform, version, state_dir, *, root=ROOT, env=None):
        try:
            parse_version(version)
        except ValueError as error:
            raise ReleaseError(str(error)) from None
        self.platform, self.version, self.state_dir = platform, version, state_dir
        self.root, self.env = root, os.environ if env is None else env
        self.name, self.number = version.split("+")
        self.client = root / "client"
        self.build = self.client / "build/apple-release" / platform
        self.output = root / "dist" / ("yggvion.ipa" if platform == "ios" else "yggvion.dmg")
        self.keychain = state_dir / "signing.keychain-db"
        self.api_key = state_dir / "AuthKey.p8"
        self.state = {"restores": []}

    def save_state(self):
        temporary = self.state_dir / "state.next"
        temporary.write_text(json.dumps(self.state))
        temporary.replace(self.state_dir / "state.json")

    def backup(self, target):
        backup = None
        if target.exists():
            backup = self.state_dir / f"backup-{len(self.state['restores'])}"
            shutil.copy2(target, backup)
        self.state["restores"].append({"target": str(target), "backup": str(backup) if backup else None})
        self.save_state()

    def prepare(self):
        prefix = validate_secrets(self.env, self.platform)
        self.team = self.env["APPLE_TEAM_ID"]
        # Refuse to overwrite a previous session's keychain or backup files.
        self.state_dir.mkdir(mode=0o700)
        self.state = {"restores": []}
        self.save_state()
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.unlink(missing_ok=True)
        if self.build.exists():
            shutil.rmtree(self.build)
        self.build.mkdir(parents=True)
        certificate = self.state_dir / "certificate.p12"
        certificate.write_bytes(decode_secret(self.env, f"{prefix}_P12_BASE64"))
        self.api_key.write_bytes(decode_secret(self.env, "APP_STORE_CONNECT_PRIVATE_KEY_BASE64"))
        certificate.chmod(0o600)
        self.api_key.chmod(0o600)
        run(["openssl", "pkey", "-in", self.api_key, "-check", "-noout"],
            label="validate App Store Connect private key", capture=True)
        search = run(["security", "list-keychains", "-d", "user"],
                     label="read keychain search list", capture=True).decode()
        self.state["keychain_search"] = shlex.split(search)
        self.save_state()
        password = secrets.token_urlsafe(32)
        run(["security", "create-keychain", "-p", password, self.keychain],
            label="create temporary keychain", capture=True)
        run(["security", "set-keychain-settings", "-lut", "21600", self.keychain],
            label="set temporary keychain lifetime", capture=True)
        run(["security", "unlock-keychain", "-p", password, self.keychain],
            label="unlock temporary keychain", capture=True)
        run(["security", "import", certificate, "-k", self.keychain, "-P", self.env[f"{prefix}_P12_PASSWORD"],
             "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"],
            label="import signing certificate and private key", capture=True)
        run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
             "-s", "-k", password, self.keychain], label="allow noninteractive signing", capture=True)
        run(["security", "list-keychains", "-d", "user", "-s", self.keychain, *self.state["keychain_search"]],
            label="make signing keychain available to Xcode", capture=True)
        identities = run(["security", "find-identity", "-v", "-p", "codesigning", self.keychain],
                         label="validate signing identity", capture=True).decode()
        self.identity = select_identity(identities, self.platform, self.team)

    def flutter_config(self):
        run(["flutter", "pub", "get", "--enforce-lockfile"], label="resolve Flutter dependencies", timeout=600)
        command = ["flutter", "build", self.platform, "--release", "--config-only",
                   f"--build-name={self.name}", f"--build-number={self.number}"]
        if self.platform == "ios":
            command.append("--no-codesign")  # Configuration only; archive is signed below.
        run(command, label="prepare Flutter and CocoaPods configuration", timeout=900)

    def check_version(self, app, *, macos=False, bundle_id=BUNDLE_ID):
        info = app / "Contents/Info.plist" if macos else app / "Info.plist"
        data = plistlib.loads(info.read_bytes())
        expected = {"CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": self.name,
                    "CFBundleVersion": self.number}
        for key, value in expected.items():
            if data.get(key) != value:
                raise ReleaseError(f"Built application {key} must be {value}; found {data.get(key)}")

    def ios(self, *, upload):
        self.profiles = {}
        for target_name, bundle_id, secret in (
            ("Runner", BUNDLE_ID, "IOS_PROVISIONING_PROFILE_BASE64"),
            ("TrackingWidget", WIDGET_BUNDLE_ID, "IOS_WIDGET_PROVISIONING_PROFILE_BASE64"),
        ):
            profile = self.state_dir / f"{target_name}.mobileprovision"
            profile.write_bytes(decode_secret(self.env, secret))
            profile.chmod(0o600)
            decoded = run(["security", "cms", "-D", "-i", profile],
                          label=f"read {target_name} distribution profile", capture=True)
            uuid = validate_profile(plistlib.loads(decoded), self.team, self.identity, bundle_id=bundle_id)
            self.profiles[bundle_id] = uuid
            # Xcode 16+ uses Developer/Xcode/UserData; support the older location too.
            for relative in ("Library/Developer/Xcode/UserData/Provisioning Profiles",
                             "Library/MobileDevice/Provisioning Profiles"):
                folder = Path.home() / relative
                folder.mkdir(parents=True, exist_ok=True)
                target = folder / f"{uuid}.mobileprovision"
                self.backup(target)
                shutil.copyfile(profile, target)
        project = self.client / "ios/Runner.xcodeproj/project.pbxproj"
        self.backup(project)
        run(["ruby", self.root / "tool/ci/configure_ios_signing.rb", project.parent,
             self.team, self.identity, self.profiles[BUNDLE_ID], self.profiles[WIDGET_BUNDLE_ID]],
            label="configure app and widget Release signing")
        self.flutter_config()
        archive = self.build / "Yggvion.xcarchive"
        run(["xcodebuild", "-workspace", "ios/Runner.xcworkspace", "-scheme", "Runner",
             "-configuration", "Release", "-destination", "generic/platform=iOS",
             "-archivePath", archive, "-derivedDataPath", self.build / "DerivedData",
             "COMPILER_INDEX_STORE_ENABLE=NO", "archive"], label="archive signed iOS app", timeout=3600)
        apps = list((archive / "Products/Applications").glob("*.app"))
        if len(apps) != 1:
            raise ReleaseError("Expected one iOS application in the archive")
        self.check_version(apps[0])
        extensions = list((apps[0] / "PlugIns").glob("*.appex"))
        if len(extensions) != 1:
            raise ReleaseError("Expected the TrackingWidget extension in the iOS archive")
        self.check_version(extensions[0], bundle_id=WIDGET_BUNDLE_ID)
        run(["codesign", "--verify", "--deep", "--strict", apps[0]], label="verify archived iOS signatures")
        export_plist = self.build / "ExportOptions.plist"
        export_plist.write_bytes(plistlib.dumps(export_options(self.team, self.identity, self.profiles)))
        export_dir = self.build / "export"
        export_command = ["xcodebuild", "-exportArchive", "-archivePath", archive,
                          "-exportOptionsPlist", export_plist, "-exportPath", export_dir]
        run(export_command, label="export signed App Store IPA", timeout=1200)
        ipas = list(export_dir.glob("*.ipa"))
        if len(ipas) != 1:
            raise ReleaseError("Xcode did not export exactly one IPA")
        if upload:
            # Xcode uploads both the build and its symbols with team API credentials.
            # No App Review or App Store publication is requested.
            export_plist.write_bytes(plistlib.dumps(export_options(
                self.team, self.identity, self.profiles, upload=True)))
            run(["xcodebuild", "-exportArchive", "-archivePath", archive,
                 "-exportOptionsPlist", export_plist, "-exportPath", self.build / "upload",
                 "-allowProvisioningUpdates", "-authenticationKeyPath", self.api_key,
                 "-authenticationKeyID", self.env["APP_STORE_CONNECT_KEY_ID"],
                 "-authenticationKeyIssuerID", self.env["APP_STORE_CONNECT_ISSUER_ID"]],
                label="upload build and symbols to App Store Connect", timeout=1800)
        shutil.copyfile(ipas[0], self.output)

    def notarize(self, dmg):
        auth = ["--key", self.api_key, "--key-id", self.env["APP_STORE_CONNECT_KEY_ID"],
                "--issuer", self.env["APP_STORE_CONNECT_ISSUER_ID"]]
        submission_error = None
        try:
            response = run(["xcrun", "notarytool", "submit", dmg, *auth, "--wait", "--timeout", "30m",
                            "--output-format", "json", "--no-progress"],
                           label="submit DMG to Apple notarization", capture=True, timeout=2100)
        except ReleaseError as error:
            if not error.output:
                raise
            submission_error = error
            response = error.output
        (self.build / "notarization.json").write_bytes(response)
        result = json.loads(response)
        if result.get("status") != "Accepted" or submission_error:
            submission = result.get("id")
            if submission:
                try:
                    log = run(["xcrun", "notarytool", "log", submission, *auth],
                              label="download notarization rejection details", capture=True)
                    (self.build / "notarization-log.json").write_bytes(log)
                except ReleaseError:
                    pass  # In-progress submissions may not have a log yet.
            raise ReleaseError(f"Apple notarization was not Accepted: {result.get('status', 'unknown')}")
        run(["xcrun", "stapler", "staple", dmg], label="staple notarization ticket", timeout=300)
        run(["xcrun", "stapler", "validate", dmg], label="validate stapled ticket")
        run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
             "--verbose=2", dmg], label="verify Gatekeeper accepts the DMG")

    def macos(self):
        self.flutter_config()
        derived = self.build / "DerivedData"
        run(["xcodebuild", "-workspace", "macos/Runner.xcworkspace", "-scheme", "Runner",
             "-configuration", "Release", "-destination", "platform=macOS", "-derivedDataPath", derived,
             "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
             "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE_SPECIFIER=", "COMPILER_INDEX_STORE_ENABLE=NO",
             "build"], label="build macOS application", timeout=3600)
        apps = list((derived / "Build/Products/Release").glob("*.app"))
        if len(apps) != 1:
            raise ReleaseError("Expected one macOS application in build products")
        app = apps[0]
        self.check_version(app, macos=True)
        run(["xattr", "-cr", app], label="remove extended attributes from built app")
        for target in signing_targets(app):
            command = ["codesign", "--force", "--sign", self.identity, "--keychain", self.keychain,
                       "--options", "runtime", "--timestamp"]
            if target == app:
                command += ["--entitlements", self.client / "macos/Runner/Release.entitlements"]
            run([*command, target], label=f"sign {target.relative_to(app.parent)}")
        run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app],
            label="verify macOS app and all nested signatures")
        stage = self.build / "dmg-stage"
        stage.mkdir()
        run(["ditto", app, stage / app.name], label="stage signed macOS app")
        (stage / "Applications").symlink_to("/Applications")
        dmg = self.build / "yggvion.dmg"
        run(["hdiutil", "create", "-volname", f"Yggvion {self.version}", "-srcfolder", stage,
             "-ov", "-format", "UDZO", dmg], label="create DMG", timeout=600)
        run(["codesign", "--force", "--sign", self.identity, "--keychain", self.keychain,
             "--timestamp", dmg], label="sign DMG")
        self.notarize(dmg)
        shutil.copyfile(dmg, self.output)  # Publish only after Accepted + staple + Gatekeeper.

    def execute(self, *, upload=False):
        if self.state_dir.exists():
            raise ReleaseError("Apple release state already exists; run cleanup first")
        try:
            self.prepare()
            if self.platform == "ios":
                self.ios(upload=upload)
            else:
                self.macos()
        finally:
            cleanup(self.state_dir)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "cleanup"))
    parser.add_argument("--platform", choices=("ios", "macos"), required=True)
    parser.add_argument("--version", help="0.1.0+1 (resolved from the release tag)")
    parser.add_argument("--upload", action="store_true", help="Upload iOS build to App Store Connect")
    args = parser.parse_args()
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or not os.environ.get("RUNNER_TEMP"):
        parser.error("This script modifies signing settings and is intended for disposable macOS GitHub runners")
    if args.action == "build" and not args.version:
        parser.error("build requires --version")
    if args.upload and args.platform != "ios":
        parser.error("--upload is only for iOS")
    # Bundled apps must remain readable by other users after DMG installation.
    # Secret files are 0600 inside the separate 0700 state directory.
    os.umask(0o022)
    os.chdir(ROOT / "client")
    state_dir = Path(os.environ["RUNNER_TEMP"]) / f"yggvion-apple-{args.platform}"

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        if args.action == "cleanup":
            cleanup(state_dir)
        else:
            AppleRelease(args.platform, args.version, state_dir).execute(upload=args.upload)
    except (ReleaseError, OSError, ValueError) as error:
        print(f"Apple release failed: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Apple release interrupted; temporary credentials cleaned up", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())

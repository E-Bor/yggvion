#!/usr/bin/env python3
"""Place remote-only shell scripts in the iOS app's resources before app signing."""
import os
from pathlib import Path
import shutil
import subprocess


SCRIPTS = ("install.sh", "uninstall.sh")


def stage_scripts(framework, resources, *, identity="-", configuration="Debug"):
    source = framework / "flutter_assets/assets/server"
    present = [(source / name).is_file() for name in SCRIPTS]
    if not any(present):
        return  # A local build without the optional VPS payloads.
    if not all(present):
        raise FileNotFoundError("Both VPS installer scripts must be bundled together")
    destination = resources / "ServerInstaller"
    destination.mkdir(parents=True, exist_ok=True)
    for name in SCRIPTS:
        shutil.copyfile(source / name, destination / name)
        (destination / name).chmod(0o644)
    for name in SCRIPTS:
        (source / name).unlink()
    # Flutter signs App.framework during assemble. Its resource seal must be
    # renewed after relocation, before Xcode signs the containing Runner.app.
    command = ["codesign", "--force", "--sign", identity or "-"]
    if configuration.lower() != "release":
        command.append("--timestamp=none")
    subprocess.run([*command, str(framework / "App")], check=True)


def verify_scripts(app):
    for name in SCRIPTS:
        resource = app / "ServerInstaller" / name
        if not resource.is_file() or resource.stat().st_size == 0:
            raise ValueError(f"Missing iOS app resource: ServerInstaller/{name}")
        if resource.stat().st_mode & 0o111:
            raise ValueError(f"VPS script must be a non-executable app resource: {name}")
        if (app / "Frameworks/App.framework/flutter_assets/assets/server" / name).exists():
            raise ValueError(f"VPS script is still inside App.framework: {name}")


def main():
    target = Path(os.environ["TARGET_BUILD_DIR"])
    framework = target / os.environ["FRAMEWORKS_FOLDER_PATH"] / "App.framework"
    resources = target / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
    stage_scripts(framework, resources,
                  identity=os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "-"),
                  configuration=os.environ.get("CONFIGURATION", "Debug"))


if __name__ == "__main__":
    main()

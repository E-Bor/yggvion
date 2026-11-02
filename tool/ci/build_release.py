#!/usr/bin/env python3
"""Package Android, Linux and Windows releases; never publish to another repository."""
import argparse
import base64
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tool.ci.release_version import ROOT, parse_version


def run(args, *, cwd, env=None):
    # Secrets are passed in the environment, never shell-expanded or logged.
    command = [str(arg) for arg in args]
    if os.name == "nt":
        command[0] = shutil.which(command[0]) or command[0]
    subprocess.run(command, cwd=cwd, env=env, check=True)


def android_keystore(env, target):
    names = ("ANDROID_KEYSTORE_BASE64", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD")
    missing = [name for name in names if not env.get(name, "").strip()]
    if missing:
        raise ValueError("Missing Android signing secrets: " + ", ".join(missing))
    try:
        data = base64.b64decode("".join(env["ANDROID_KEYSTORE_BASE64"].split()), validate=True)
    except ValueError:
        raise ValueError("ANDROID_KEYSTORE_BASE64 must be a Base64 keystore.") from None
    if not data:
        raise ValueError("The Android keystore is empty.")
    # Refuse to overwrite a pre-existing key; exclusive open also rejects symlinks.
    with target.open("xb") as stream:
        target.chmod(0o600)
        stream.write(data)


def build_android(client, output, version, env):
    temporary = Path(env.get("RUNNER_TEMP", tempfile.gettempdir())) / "yggvion-release.jks"
    android_keystore(env, temporary)
    try:
        build_env = {**env, "ANDROID_KEYSTORE_PATH": str(temporary)}
        name, number = parse_version(version)
        run(["flutter", "build", "apk", "--release", f"--build-name={name}", f"--build-number={number}"],
            cwd=client, env=build_env)
        apk = client / "build/app/outputs/flutter-apk/app-release.apk"
        sdk = env.get("ANDROID_SDK_ROOT") or env.get("ANDROID_HOME")
        tools = list((Path(sdk) / "build-tools").glob("*/apksigner")) if sdk else []
        if not tools:
            raise ValueError("Android SDK apksigner is required to verify the release APK.")
        run([max(tools, key=lambda path: path.stat().st_mtime), "verify", apk], cwd=client)
        shutil.copyfile(apk, output)
    finally:
        temporary.unlink(missing_ok=True)


def stage_deb(bundle, stage, icon, version):
    """Stage a relocatable Flutter bundle with desktop and URI-handler registration."""
    parse_version(version)
    destination = stage / "opt/yggvion"
    shutil.copytree(bundle, destination, symlinks=True)
    (destination / "yggvion").chmod(0o755)
    for folder in ("DEBIAN", "usr/bin", "usr/share/applications", "usr/share/icons/hicolor/256x256/apps"):
        (stage / folder).mkdir(parents=True, exist_ok=True)
    (stage / "usr/bin/yggvion").symlink_to("/opt/yggvion/yggvion")
    (stage / "DEBIAN/control").write_text(
        f"Package: yggvion\nVersion: {version}\nSection: utils\nPriority: optional\nArchitecture: amd64\n"
        "Maintainer: Yggvion maintainers\n"
        "Depends: libgtk-3-0, libstdc++6, libc6 (>= 2.39), libglib2.0-0, libayatana-appindicator3-1\n"
        "Description: Personal calendar, Markdown notes and time tracking\n"
    )
    (stage / "usr/share/applications/yggvion.desktop").write_text(
        "[Desktop Entry]\nName=Yggvion\nComment=Calendar, notes and time tracking\n"
        "Exec=/usr/bin/yggvion %u\nTryExec=/usr/bin/yggvion\nIcon=yggvion\n"
        "Terminal=false\nType=Application\nCategories=Office;Calendar;\n"
        "MimeType=x-scheme-handler/yggvion;\nStartupWMClass=dev.yggvion.yggvion\n"
    )
    shutil.copyfile(icon, stage / "usr/share/icons/hicolor/256x256/apps/yggvion.png")


def stage_windows_runtime(bundle, redist):
    """Include the app-local Visual C++ runtime so a clean Windows install can launch."""
    required = ("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")
    candidates = sorted(
        redist.glob("*/x64/Microsoft.VC*.CRT"),
        key=lambda path: tuple(int(part) for part in re.findall(r"\d+", path.parent.parent.name)),
        reverse=True,
    )
    runtime = next((path for path in candidates if all((path / name).is_file() for name in required)), None)
    if runtime is None:
        raise ValueError("Visual Studio's x64 C++ redistributable DLLs were not found.")
    for library in runtime.glob("*.dll"):
        shutil.copy2(library, bundle / library.name)


def build_desktop(platform, client, output, version):
    name, number = parse_version(version)
    run(["flutter", "build", platform, "--release", f"--build-name={name}", f"--build-number={number}"], cwd=client)
    if platform == "linux":
        with tempfile.TemporaryDirectory(prefix="yggvion-deb-") as folder:
            stage = Path(folder) / "package"
            stage_deb(client / "build/linux/x64/release/bundle", stage,
                      client / "linux/runner/yggvion.png", version)
            run(["dpkg-deb", "--root-owner-group", "--build", stage, output], cwd=client)
    else:
        bundle = client / "build/windows/x64/runner/Release"
        vswhere = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
        installation = subprocess.check_output(
            [str(vswhere), "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
             "-property", "installationPath", "-utf8"], text=True, encoding="utf-8",
        ).strip()
        if not installation:
            raise ValueError("Visual Studio C++ tools are required for the Windows installer.")
        stage_windows_runtime(bundle, Path(installation) / "VC/Redist/MSVC")
        candidates = [shutil.which("iscc"), r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
                      r"C:\Program Files\Inno Setup 6\ISCC.exe"]
        compiler = next((path for path in candidates if path and Path(path).is_file()), None)
        if not compiler:
            raise ValueError("Inno Setup 6 is required to package the Windows installer.")
        run([compiler, f"/DAppVersion={version}", f"/DFileVersion={name}.{number}",
             f"/DSourceDir={bundle}", f"/DOutputDir={output.parent}",
             ROOT / "tool/ci/windows.iss"], cwd=client)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("android", "linux", "windows"), required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    try:
        parse_version(args.version)
        expected = {"android": ("linux", "darwin"), "linux": ("linux",), "windows": ("win32",)}
        if sys.platform not in expected[args.platform]:
            raise ValueError("This release target requires its native build host.")
        client = ROOT / "client"
        output = ROOT / "dist" / ("yggvion." + {"android": "apk", "linux": "deb", "windows": "exe"}[args.platform])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.unlink(missing_ok=True)
        run(["flutter", "pub", "get", "--enforce-lockfile"], cwd=client)
        if args.platform == "android":
            build_android(client, output, args.version, dict(os.environ))
        else:
            build_desktop(args.platform, client, output, args.version)
        if not output.is_file() or output.stat().st_size == 0:
            raise ValueError("The release installer was not produced.")
        print(f"Installer ready: {output.name}")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Resolve a release tag and the requested native build matrix without secrets."""
import argparse
import json
import os
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
VERSION_PATTERN = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+([1-9][0-9]*)"
)
TARGETS = {
    "android": {"os": "ubuntu-24.04", "installer": "yggvion.apk"},
    "ios": {"os": "macos-26", "installer": "yggvion.ipa"},
    "macos": {"os": "macos-26", "installer": "yggvion.dmg"},
    "linux": {"os": "ubuntu-24.04", "installer": "yggvion.deb"},
    "windows": {"os": "windows-2022", "installer": "yggvion.exe"},
}


def parse_version(version):
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError("Release version must be 0.1.0+1: no v prefix, positive build number.")
    name, number = version.split("+")
    # A single integer must fit CFBundleVersion's first component on Apple platforms.
    if int(number) > 9999:
        raise ValueError("The Apple build number must be between 1 and 9999.")
    return name, number


def resolve_version(env, root=ROOT):
    if env.get("GITHUB_REF_TYPE") == "tag":
        version = env.get("GITHUB_REF_NAME", "")
    else:
        match = re.search(r"^version:\s*([^\s#]+)", (root / "client/pubspec.yaml").read_text(), re.M)
        if not match:
            raise ValueError("client/pubspec.yaml has no version.")
        version = match.group(1)
    parse_version(version)
    return version


def build_matrix(target):
    if target != "all" and target not in TARGETS:
        raise ValueError("Unknown release target.")
    return {"include": [
        {"target": name, **settings}
        for name, settings in TARGETS.items() if target in ("all", name)
    ]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=("all", *TARGETS), default="all")
    args = parser.parse_args()
    try:
        version = resolve_version(os.environ)
        name, number = parse_version(version)
        values = {
            "version": version, "build_name": name, "build_number": number,
            "matrix": json.dumps(build_matrix(args.target), separators=(",", ":")),
        }
    except ValueError as error:
        parser.error(str(error))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as stream:
            for key, value in values.items():
                stream.write(f"{key}={value}\n")
    print(f"Release {version}; targets: {args.target}")


if __name__ == "__main__":
    main()

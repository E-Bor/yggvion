#!/usr/bin/env python3
"""Publish the complete native build set as a GitHub pre-release."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tool.ci.release_version import ROOT, TARGETS, parse_version


APP_STORE_URL = "https://apps.apple.com/app/id6829935844"


def gh(*args):
    # Authentication stays in GH_TOKEN; never pass it in command arguments.
    return subprocess.run(
        ["gh", *map(str, args)], check=True, text=True, stdout=subprocess.PIPE,
    ).stdout


def find_release(repository, version):
    # Listing also finds unpublished drafts left by an interrupted upload.
    pages = json.loads(gh("api", f"repos/{repository}/releases?per_page=100", "--paginate", "--slurp"))
    matches = [item for page in pages for item in page if item["tag_name"] == version]
    if len(matches) > 1:
        raise ValueError(f"Multiple releases use {version}; resolve the duplicate drafts first.")
    return matches[0] if matches else None


def release_notes(repository, version):
    name, number = parse_version(version)
    downloads = f"https://github.com/{repository}/releases/download/{quote(version, safe='')}"
    lines = [
        f"Yggvion {name} (build {number}).", "",
        f"**iPhone and iPad:** [Download on the App Store]({APP_STORE_URL}).", "",
        "The App Store version becomes available after Apple's review and release.", "",
        "| Platform | Download |", "| --- | --- |",
    ]
    labels = {"android": "Android", "ios": "iOS (App Store IPA)", "macos": "macOS",
              "linux": "Linux (DEB)", "windows": "Windows"}
    for target, settings in TARGETS.items():
        installer = settings["installer"]
        lines.append(f"| {labels[target]} | [{installer}]({downloads}/{installer}) |")
    lines.extend([
        "", "The IPA is an App Store distribution build. Install the iOS app through the App Store; "
        "the IPA cannot be installed directly like an Android APK.", "",
    ])
    return "\n".join(lines)


def publish_release(repository, version, directory):
    parse_version(version)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("GITHUB_REPOSITORY must identify the current owner/repository.")
    assets = [directory / settings["installer"] for settings in TARGETS.values()]
    for asset in assets:
        if asset.is_symlink() or not asset.is_file() or asset.stat().st_size == 0:
            raise ValueError(f"Missing or empty installer: {asset.name}")

    url = f"https://github.com/{repository}/releases/tag/{quote(version, safe='')}"
    existing = find_release(repository, version)
    if existing is not None and not existing["draft"]:
        # A rerun must preserve a published release, including manual promotion.
        uploaded = {asset["name"] for asset in existing["assets"] if asset["state"] == "uploaded"}
        missing = {asset.name for asset in assets} - uploaded
        if missing:
            raise ValueError("Published release is missing installers: " + ", ".join(sorted(missing)))
        print(f"Release already published; keeping its assets and status: {url}")
        return url

    with tempfile.TemporaryDirectory(prefix="yggvion-release-") as temporary:
        notes = Path(temporary) / "notes.md"
        notes.write_text(release_notes(repository, version), encoding="utf-8")
        title = f"Yggvion {version}"
        if existing is None:
            gh("release", "create", version, "--repo", repository, "--verify-tag",
               "--draft", "--prerelease", "--latest=false", "--title", title, "--notes-file", notes)
        else:
            gh("release", "edit", version, "--repo", repository,
               "--title", title, "--notes-file", notes)
        # Only drafts are changed; failed uploads remain unpublished and can be retried.
        gh("release", "upload", version, *assets, "--repo", repository, "--clobber")
        gh("release", "edit", version, "--repo", repository, "--verify-tag",
           "--draft=false", "--prerelease", "--latest=false")
    print(f"Published pre-release: {url}")
    return url


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--directory", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    if (os.environ.get("GITHUB_EVENT_NAME") != "push"
            or os.environ.get("GITHUB_REF_TYPE") != "tag"
            or os.environ.get("GITHUB_REF_NAME") != args.version):
        parser.error("Pre-releases are published only for the tag pushed in this workflow run.")
    try:
        url = publish_release(os.environ.get("GITHUB_REPOSITORY", ""), args.version, args.directory)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"GitHub release failed: {error}\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as stream:
            stream.write(f"### [GitHub release {args.version}]({url})\n\n"
                         "All five platform builds are attached. To promote a pre-release, edit it, "
                         "uncheck **This is a pre-release**, select **Set as latest release**, "
                         "and save.\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build pinned Linux installer payloads from this exact repository checkout."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
target = root / "client/assets/server"
target.mkdir(parents=True, exist_ok=True)
manifest = {}
for arch in ("amd64", "arm64"):
    name = f"yggvion-linux-{arch}"
    subprocess.run(
        ["go", "build", "-trimpath", "-ldflags=-s -w", "-o", str(target / name), "./cmd/yggvion"],
        cwd=root / "server", env={**os.environ, "GOOS": "linux", "GOARCH": arch, "CGO_ENABLED": "0"}, check=True,
    )
    digest = hashlib.sha256()
    with (target / name).open("rb") as artifact:
        for chunk in iter(lambda: artifact.read(1024 * 1024), b""):
            digest.update(chunk)
    manifest[arch] = {"file": name, "sha256": digest.hexdigest()}
shutil.copyfile(root / "deploy/install.sh", target / "install.sh")
(target / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Server installer assets built for Linux amd64/arm64.")

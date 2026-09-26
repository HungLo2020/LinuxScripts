#!/usr/bin/env python3
"""Install Cloudflare's tunnel connector for the read-only package origins."""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request

RELEASES = {
    "x86_64": "cloudflared-linux-amd64.deb",
    "aarch64": "cloudflared-linux-arm64.deb",
}


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def main() -> int:
    if os.geteuid() != 0:
        print("Run this script with sudo on the repository server.", file=sys.stderr)
        return 1
    if shutil.which("cloudflared"):
        print("cloudflared is already installed.")
        return 0
    package = RELEASES.get(platform.machine())
    if not package:
        print(f"Unsupported server architecture: {platform.machine()}", file=sys.stderr)
        return 1
    url = f"https://github.com/cloudflare/cloudflared/releases/latest/download/{package}"
    request = urllib.request.Request(url, headers={"User-Agent": "LinuxScripts-repository-tunnel/1.0"})
    with tempfile.NamedTemporaryFile(suffix=".deb") as temporary:
        with urllib.request.urlopen(request, timeout=60) as response:
            shutil.copyfileobj(response, temporary)
        temporary.flush()
        run("apt-get", "install", "-y", temporary.name)
    print("cloudflared installed; tunnel credentials and routes are still required.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

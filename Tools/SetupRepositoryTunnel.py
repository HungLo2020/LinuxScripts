#!/usr/bin/env python3
"""Install Cloudflare's tunnel connector for the read-only package origins."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

KEY_URL = "https://pkg.cloudflare.com/cloudflare-main.gpg"
KEY_PATH = Path("/usr/share/keyrings/cloudflare-main.gpg")
SOURCE_PATH = Path("/etc/apt/sources.list.d/cloudflared.list")
SOURCE_LINE = f"deb [signed-by={KEY_PATH}] https://pkg.cloudflare.com/cloudflared any main\n"


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def main() -> int:
    if os.geteuid() != 0:
        print("Run this script with sudo on the repository server.", file=sys.stderr)
        return 1
    if shutil.which("cloudflared"):
        print("cloudflared is already installed.")
        return 0
    with urllib.request.urlopen(KEY_URL, timeout=30) as response:
        key = response.read()
    with tempfile.NamedTemporaryFile() as temporary:
        temporary.write(key)
        temporary.flush()
        run("install", "-d", "-m", "0755", str(KEY_PATH.parent))
        run("install", "-m", "0644", temporary.name, str(KEY_PATH))
    SOURCE_PATH.write_text(SOURCE_LINE, encoding="utf-8")
    run("apt-get", "update")
    run("apt-get", "install", "-y", "cloudflared")
    print("cloudflared installed; tunnel credentials and routes are still required.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

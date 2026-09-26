#!/usr/bin/env python3
"""Show non-secret prerequisites for moving public package downloads to this server."""

from __future__ import annotations

import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from bitwarden import BitwardenClient, BitwardenError


def main() -> int:
    print(f"cloudflared installed: {shutil.which('cloudflared') is not None}")
    for name, port, suite in (("mattos", 8791, "trixie"), ("mattpackages", 8792, "stable")):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/dists/{suite}/InRelease", timeout=5) as response:
                valid = b"BEGIN PGP SIGNED MESSAGE" in response.read(64)
                cache = response.headers.get("Cache-Control")
        except (urllib.error.HTTPError, urllib.error.URLError) as exc:
            print(f"{name} public endpoint unavailable: {exc}")
            continue
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/v2/repos/{name}/private-key", timeout=5):
                private_route = "exposed"
        except urllib.error.HTTPError as exc:
            private_route = "blocked" if exc.code == 404 else f"unexpected HTTP {exc.code}"
        except urllib.error.URLError as exc:
            private_route = f"unavailable: {exc}"
        print(f"{name} public endpoint: {'healthy' if valid and cache == 'no-store' and private_route == 'blocked' else 'check required'}")
    try:
        client = BitwardenClient(password_file=None)
        names = sorted({str(item.get("name")) for item in client.list_items("Cloudflare") if item.get("name")})
        print("Cloudflare Bitwarden item names: " + (", ".join(names) if names else "none found"))
    except BitwardenError as exc:
        print(f"Bitwarden inspection unavailable: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

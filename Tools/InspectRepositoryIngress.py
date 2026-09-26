#!/usr/bin/env python3
"""Show non-secret prerequisites for moving public package downloads to this server."""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from bitwarden import BitwardenClient, BitwardenError


def main() -> int:
    print(f"cloudflared installed: {shutil.which('cloudflared') is not None}")
    password_file = Path.home() / "Documents/Repos/LinuxScripts/.bw_master_password"
    try:
        client = BitwardenClient(password_file=password_file, non_interactive=True)
        names = sorted({str(item.get("name")) for item in client.list_items("Cloudflare") if item.get("name")})
        print("Cloudflare Bitwarden item names: " + (", ".join(names) if names else "none found"))
    except BitwardenError as exc:
        print(f"Bitwarden inspection unavailable: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

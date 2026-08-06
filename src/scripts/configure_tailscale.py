#!/usr/bin/env python3
"""Enable Tailscale and complete its interactive device authentication."""

from __future__ import annotations

import subprocess
import sys


def main() -> int:
    subprocess.run(("sudo", "systemctl", "enable", "--now", "tailscaled"), check=True)
    print("Starting Tailscale authentication. Complete the browser sign-in if prompted.")
    subprocess.run(("sudo", "tailscale", "up"), check=True)
    subprocess.run(("tailscale", "status"), check=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f"Error: Tailscale setup failed: {error}", file=sys.stderr)
        raise SystemExit(error.returncode or 1) from error
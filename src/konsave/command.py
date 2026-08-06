"""Resolve the Konsave command without modifying the project environment."""

from __future__ import annotations

import os
from pathlib import Path

from process import find_command


def resolve_konsave_command() -> list[str]:
    """Return Konsave's command, preferring an installed executable over pipx."""

    local_bin = Path.home() / ".local" / "bin"
    os.environ["PATH"] = f"{local_bin}{os.pathsep}{os.environ.get('PATH', '')}"

    executable = find_command("konsave")
    if executable is not None:
        return [executable]

    pipx = find_command("pipx")
    if pipx is not None:
        return [pipx, "run", "konsave"]

    raise RuntimeError(
        "Konsave was not found, and pipx is unavailable. Install Konsave with "
        "'pipx install konsave' or install pipx to run it on demand."
    )
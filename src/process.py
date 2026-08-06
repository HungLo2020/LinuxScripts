"""Safe subprocess helpers for invoking existing platform tools."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import Sequence


def require_command(command: str) -> str:
    """Return an executable path or raise an actionable error."""

    executable = shutil.which(command)
    if executable is None:
        raise RuntimeError(f"Required command was not found: {command}")
    return executable


def run_command(
    command: Sequence[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    capture_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    """Run an external command without shell parsing or word splitting."""

    return subprocess.run(
        list(command),
        cwd=cwd,
        check=check,
        text=True,
        capture_output=capture_output,
    )
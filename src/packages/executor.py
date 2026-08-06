"""Execute an already reviewed package-provider command plan."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from collections.abc import Iterable

from packages.models import CommandSpec, ProviderOperation, ScriptOperation
from process import require_command, run_command


def _command_with_privileges(command: CommandSpec) -> tuple[str, ...]:
    if not command.elevated or os.name == "nt" or os.geteuid() == 0:
        return command.argv
    return (require_command("sudo"), *command.argv)


def _script_path(repository_root: Path, script: str) -> Path:
    path = repository_root / "src" / "scripts" / script
    if not path.is_file():
        raise RuntimeError(f"Dependency script does not exist: {path}")
    return path


def validate_script_dependencies(operations: Iterable[ProviderOperation | ScriptOperation], repository_root: Path) -> None:
    """Fail planning before package installation when a declared script is unavailable."""

    for operation in operations:
        if isinstance(operation, ScriptOperation):
            _script_path(repository_root, operation.script)


def execute_operations(operations: Iterable[ProviderOperation | ScriptOperation], repository_root: Path) -> None:
    """Execute provider operations in their planned order."""

    for operation in operations:
        if isinstance(operation, ScriptOperation):
            script = _script_path(repository_root, operation.script)
            print(operation.description)
            run_command((sys.executable, str(script)), cwd=repository_root)
            continue
        print(f"Provider: {operation.provider} ({', '.join(operation.packages)})")
        for command in operation.commands:
            print(f"  {command.description}")
            run_command(_command_with_privileges(command))
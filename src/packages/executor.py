"""Execute an already reviewed package-provider command plan."""

from __future__ import annotations

import os
from collections.abc import Iterable

from packages.models import CommandSpec, ProviderOperation
from process import require_command, run_command


def _command_with_privileges(command: CommandSpec) -> tuple[str, ...]:
    if not command.elevated or os.name == "nt" or os.geteuid() == 0:
        return command.argv
    return (require_command("sudo"), *command.argv)


def execute_operations(operations: Iterable[ProviderOperation]) -> None:
    """Execute provider operations in their planned order."""

    for operation in operations:
        print(f"Provider: {operation.provider} ({', '.join(operation.packages)})")
        for command in operation.commands:
            print(f"  {command.description}")
            run_command(_command_with_privileges(command))
"""Execute an already reviewed package-provider command plan."""

from __future__ import annotations

import hashlib
import os
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path
from collections.abc import Iterable

if os.name != "nt":
    import fcntl

from packages.models import CommandSpec, ProviderOperation, ScriptOperation
from process import find_command, require_command, run_command


def _command_with_privileges(command: CommandSpec) -> tuple[str, ...]:
    if not command.elevated or os.name == "nt" or os.geteuid() == 0:
        return command.argv
    return (require_command("sudo"), *command.argv)


def _script_path(repository_root: Path, script: str) -> Path:
    path = repository_root / "src" / "scripts" / script
    if not path.is_file():
        raise RuntimeError(f"Dependency script does not exist: {path}")
    return path


def _refresh_windows_path() -> None:
    """Load persisted Windows PATH entries after an installer updates them."""

    if os.name != "nt":
        return

    import winreg

    entries = os.environ.get("PATH", "").split(os.pathsep)
    for hive, key in ((winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"), (winreg.HKEY_CURRENT_USER, "Environment")):
        try:
            with winreg.OpenKey(hive, key) as environment_key:
                value, _ = winreg.QueryValueEx(environment_key, "Path")
        except OSError:
            continue
        entries.extend(os.path.expandvars(value).split(os.pathsep))

    unique_entries = list(dict.fromkeys(entry for entry in entries if entry))
    os.environ["PATH"] = os.pathsep.join(unique_entries)


def _prepare_provider(provider: str) -> None:
    if os.name != "nt":
        return

    _refresh_windows_path()
    if provider != "npm" or find_command("npm") is not None:
        return

    for variable, relative_path in (("ProgramFiles", "nodejs"), ("LOCALAPPDATA", "Programs\\nodejs")):
        base_path = os.environ.get(variable)
        if base_path is None:
            continue
        candidate = str(Path(base_path) / relative_path)
        if Path(candidate).is_dir():
            os.environ["PATH"] = os.environ["PATH"] + os.pathsep + candidate

    if find_command("npm") is None:
        raise RuntimeError("npm was not found after installing Node.js. Close and reopen PowerShell, then rerun the package apply command.")


def validate_script_dependencies(operations: Iterable[ProviderOperation | ScriptOperation], repository_root: Path) -> None:
    """Fail planning before package installation when a declared script is unavailable."""

    for operation in operations:
        if isinstance(operation, ScriptOperation):
            _script_path(repository_root, operation.script)


@contextmanager
def execution_lock(repository_root: Path):
    """Prevent concurrent package applies for the same checkout on POSIX hosts."""

    if os.name == "nt":
        yield
        return
    lock_name = hashlib.sha256(str(repository_root.resolve()).encode("utf-8")).hexdigest()[:16]
    lock_path = Path(tempfile.gettempdir()) / f"linuxscripts-package-apply-{lock_name}.lock"
    with lock_path.open("a+", encoding="utf-8") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError(f"Another package apply is already running for this checkout ({lock_path}).") from error
        try:
            yield
        finally:
            fcntl.flock(lock_file, fcntl.LOCK_UN)


def execute_operations(operations: Iterable[ProviderOperation | ScriptOperation], repository_root: Path) -> None:
    """Execute provider operations in their planned order."""

    with execution_lock(repository_root):
        for operation in operations:
            if isinstance(operation, ScriptOperation):
                script = _script_path(repository_root, operation.script)
                print(operation.description)
                run_command((sys.executable, str(script)), cwd=repository_root)
                continue
            _prepare_provider(operation.provider)
            print(f"Provider: {operation.provider} ({', '.join(operation.packages)})")
            for command in operation.commands:
                print(f"  {command.description}")
                run_command(_command_with_privileges(command))
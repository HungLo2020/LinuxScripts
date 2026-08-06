#!/usr/bin/env python3
"""Plan and apply declarative LinuxScripts package profiles."""

from __future__ import annotations

import argparse
import os
import shlex
import sys
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRECTORY = REPOSITORY_ROOT / "src"


def use_project_interpreter() -> None:
    """Re-execute with the bootstrapped virtual environment when it exists."""

    venv_python = REPOSITORY_ROOT / ".venv" / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    if venv_python.is_file() and Path(sys.executable).resolve() != venv_python.resolve():
        os.execv(str(venv_python), (str(venv_python), *sys.argv))


use_project_interpreter()

if str(SOURCE_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SOURCE_DIRECTORY))

from host import detect_host
from packages.catalog import load_catalog, load_profiles
from packages.executor import execute_operations, validate_script_dependencies
from packages.planner import PackageResolutionError, resolve_profiles
from packages.models import ScriptOperation
from packages.providers import ProviderPlanningError, plan_execution_steps, preferred_provider
from paths import find_repository_root
from system import PackageManager, detect_package_manager, detect_package_platform


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)

    subcommands.add_parser("profiles", help="List available package profiles.")
    for command_name, help_text in (("plan", "Display a package plan without changing the system."), ("apply", "Apply a package plan.")):
        command = subcommands.add_parser(command_name, help=help_text)
        command.add_argument("profiles", nargs="+", help="One or more profile names to resolve.")
        if command_name == "plan":
            command.add_argument("--platform", choices=("linux", "mattos", "windows", "macos"), help="Override the detected platform for planning.")
            command.add_argument(
                "--package-manager",
                choices=tuple(manager.value for manager in PackageManager),
                help="Override the detected Linux package manager for planning.",
            )
        else:
            command.add_argument("--yes", action="store_true", help="Required acknowledgement before executing the plan.")
    return parser.parse_args()


def load_resources(repository_root: Path):
    """Load the catalog and profiles stored in the repository resources directory."""

    catalog = load_catalog(repository_root / "resources" / "packages")
    profiles = load_profiles(repository_root / "resources" / "profiles")
    return catalog, profiles


def resolve_command_plan(args: argparse.Namespace):
    """Resolve package profiles and provider commands from CLI options."""

    repository_root = find_repository_root(Path(__file__).parent)
    catalog, profiles = load_resources(repository_root)
    host = detect_host()
    platform_name = getattr(args, "platform", None) or detect_package_platform(host)
    requested_manager = getattr(args, "package_manager", None)
    package_manager = PackageManager(requested_manager) if requested_manager else None
    if package_manager is None and platform_name in {"linux", "mattos"} and host.system == "linux":
        package_manager = detect_package_manager()

    provider_preferences = (preferred_provider(package_manager),) if package_manager else ()
    package_plan = resolve_profiles(args.profiles, catalog, profiles, platform_name, provider_preferences)
    operations = plan_execution_steps(
        package_plan.packages,
        package_plan.profile_scripts,
        package_manager,
        package_plan.delete_packages,
    )
    validate_script_dependencies(operations, repository_root)
    return host, platform_name, package_manager, package_plan, operations


def print_plan(host, platform_name, package_manager, package_plan, operations) -> None:
    """Render a human-readable plan before any provider execution."""

    print(f"Host: {host.system}/{host.architecture}")
    print(f"Plan platform: {platform_name}")
    print(f"Native package manager: {package_manager.value if package_manager else 'not applicable'}")
    print(f"Profiles: {', '.join(package_plan.profiles)}")
    print("Resolved packages:")
    for package in package_plan.packages:
        print(f"  {package.name}: {package.target.provider}/{package.target.identifier}")
    if package_plan.skipped:
        print("Skipped packages:")
        for name, reason in package_plan.skipped.items():
            print(f"  {name}: {reason}")
    print("Provider operations:")
    for operation in operations:
        if isinstance(operation, ScriptOperation):
            print(f"  script: {operation.script}")
            print(f"    {operation.description}")
            continue
        print(f"  {operation.provider}: {', '.join(operation.packages)}")
        for command in operation.commands:
            privilege = "sudo " if command.elevated else ""
            print(f"    {privilege}{shlex.join(command.argv)}")


def main() -> int:
    args = parse_args()
    repository_root = find_repository_root(Path(__file__).parent)
    _, profiles = load_resources(repository_root)
    if args.command == "profiles":
        for profile in profiles.values():
            print(f"{profile.name}: {profile.description}")
        return 0

    try:
        host, platform_name, package_manager, package_plan, operations = resolve_command_plan(args)
    except (PackageResolutionError, ProviderPlanningError, RuntimeError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1

    print_plan(host, platform_name, package_manager, package_plan, operations)
    if args.command == "plan":
        return 0
    if not args.yes:
        print("Error: apply requires --yes after reviewing the plan.", file=sys.stderr)
        return 2

    execute_operations(operations, repository_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
"""Load and validate declarative package and profile TOML resources."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from packages.models import PackageDefinition, PackageTarget, ProfileDefinition, ProfilePackage
from toml_reader import load_toml


def _string_list(value: Any, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise ValueError(f"{label} must be a list of non-empty strings.")
    return tuple(value)


def load_package(path: Path) -> PackageDefinition:
    """Load one logical package and all of its provider targets."""

    document = load_toml(path)
    entry = document.get("package")
    if not isinstance(entry, dict):
        raise ValueError(f"{path} must contain a [package] table.")
    name = entry.get("name")
    description = entry.get("description", "")
    if not isinstance(name, str) or not name:
        raise ValueError(f"{path} package name must be a non-empty string.")
    if not isinstance(description, str):
        raise ValueError(f"Package '{name}' description must be a string.")
    package_dependencies = _string_list(entry.get("depends_on", []), f"Package '{name}' depends_on")
    target_entries = document.get("targets", {})
    if not isinstance(target_entries, dict):
        raise ValueError(f"Package '{name}' targets must be a table.")

    targets: list[PackageTarget] = []
    for platform_name, providers in target_entries.items():
        if not isinstance(providers, dict):
            raise ValueError(f"Package '{name}' target platform '{platform_name}' must be a table.")
        for provider_name, target in providers.items():
            if not isinstance(target, dict) or not isinstance(target.get("id"), str):
                raise ValueError(f"Package '{name}' target '{platform_name}.{provider_name}' needs an id.")
            target_dependencies = _string_list(
                target.get("depends_on", []),
                f"Package '{name}' target '{platform_name}.{provider_name}' depends_on",
            )
            options = {
                key: value
                for key, value in target.items()
                if key not in {"id", "depends_on"} and isinstance(value, str)
            }
            targets.append(PackageTarget(platform_name, provider_name, target["id"], target_dependencies, options))

    if not targets:
        raise ValueError(f"Package '{name}' must define at least one target.")
    return PackageDefinition(name, description, package_dependencies, tuple(targets))


def load_catalog(directory: Path) -> dict[str, PackageDefinition]:
    """Load package files recursively and reject duplicate logical names."""

    catalog: dict[str, PackageDefinition] = {}
    for path in sorted(directory.rglob("*.toml")):
        package = load_package(path)
        if package.name in catalog:
            raise ValueError(f"Duplicate package name: {package.name}")
        catalog[package.name] = package
    return catalog


def _profile_packages(value: Any, label: str) -> tuple[ProfilePackage, ...]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a table.")
    required = _string_list(value.get("required_packages", []), f"{label} required_packages")
    optional = _string_list(value.get("optional_packages", []), f"{label} optional_packages")
    duplicated = set(required).intersection(optional)
    if duplicated:
        names = ", ".join(sorted(duplicated))
        raise ValueError(f"{label} lists packages as both required and optional: {names}")
    return tuple(ProfilePackage(name, True) for name in required) + tuple(ProfilePackage(name, False) for name in optional)


def _platform_profile_packages(value: Any, profile_name: str) -> dict[str, tuple[ProfilePackage, ...]]:
    if not isinstance(value, dict):
        raise ValueError(f"Profile '{profile_name}' platforms must be a table.")
    packages_by_platform: dict[str, tuple[ProfilePackage, ...]] = {}
    for platform_name, platform_entry in value.items():
        if not isinstance(platform_name, str) or not platform_name:
            raise ValueError(f"Profile '{profile_name}' platform names must be non-empty strings.")
        if not isinstance(platform_entry, dict):
            raise ValueError(f"Profile '{profile_name}' platform '{platform_name}' must be a table.")
        packages_by_platform[platform_name] = _profile_packages(
            platform_entry,
            f"Profile '{profile_name}' platform '{platform_name}'",
        )
    return packages_by_platform


def load_profile(path: Path) -> ProfileDefinition:
    """Load one composable package profile."""

    document = load_toml(path)
    profile = document.get("profile")
    if not isinstance(profile, dict):
        raise ValueError(f"{path} must contain a [profile] table.")
    name = profile.get("name")
    description = profile.get("description", "")
    if not isinstance(name, str) or not name:
        raise ValueError(f"{path} profile name must be a non-empty string.")
    if not isinstance(description, str):
        raise ValueError(f"{path} profile description must be a string.")
    return ProfileDefinition(
        name,
        description,
        _string_list(profile.get("includes", []), f"Profile '{name}' includes"),
        _profile_packages(profile, f"Profile '{name}'"),
        _platform_profile_packages(document.get("platforms", {}), name),
    )


def load_profiles(directory: Path) -> dict[str, ProfileDefinition]:
    """Load every TOML profile in a directory and reject duplicate names."""

    profiles: dict[str, ProfileDefinition] = {}
    for path in sorted(directory.glob("*.toml")):
        profile = load_profile(path)
        if profile.name in profiles:
            raise ValueError(f"Duplicate profile name: {profile.name}")
        profiles[profile.name] = profile
    return profiles
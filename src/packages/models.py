"""Typed data structures for package catalogs and profile definitions."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping


@dataclass(frozen=True)
class PackageTarget:
    """One provider-specific way to install a logical package."""

    platform: str
    provider: str
    identifier: str
    dependencies: tuple[str, ...]
    options: Mapping[str, str]


@dataclass(frozen=True)
class PackageDefinition:
    """A logical package with dependencies and platform-specific targets."""

    name: str
    description: str
    dependencies: tuple[str, ...]
    targets: tuple[PackageTarget, ...]


@dataclass(frozen=True)
class ProfilePackage:
    """One logical package requested by a profile and its support requirement."""

    name: str
    required: bool


@dataclass(frozen=True)
class ProfileDefinition:
    """A composable set of logical packages and other profiles."""

    name: str
    description: str
    includes: tuple[str, ...]
    packages: tuple[ProfilePackage, ...]
    platform_packages: Mapping[str, tuple[ProfilePackage, ...]]


@dataclass(frozen=True)
class ResolvedPackage:
    """A logical package paired with its selected host-specific target."""

    name: str
    target: PackageTarget


@dataclass(frozen=True)
class PackagePlan:
    """The resolved installation order and platform-specific omissions."""

    profiles: tuple[str, ...]
    packages: tuple[ResolvedPackage, ...]
    skipped: Mapping[str, str]


@dataclass(frozen=True)
class CommandSpec:
    """One platform command generated from a provider operation."""

    argv: tuple[str, ...]
    description: str
    elevated: bool = False


@dataclass(frozen=True)
class ProviderOperation:
    """A batched provider operation and the commands needed to perform it."""

    provider: str
    packages: tuple[str, ...]
    commands: tuple[CommandSpec, ...]
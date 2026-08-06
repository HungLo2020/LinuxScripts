# Resources

Declarative data consumed by `Tools/Setup.py`.

## Profiles

`profiles/*.toml` compose named package sets. Common packages belong in `[profile]`; operating-system-specific policy belongs in `[platforms.<os>]`.

```toml
[profile]
name = "example"
includes = ["base"]
required_packages = ["git"]
optional_packages = []

[platforms.linux]
required_packages = ["fastfetch"]
optional_packages = []
delete_packages = ["unwanted-package"]
```

`delete_packages` contains native provider identifiers, not logical package resource names. It is currently supported for guarded APT removal and runs after profile installations. See [../Docs/PackageManagement.md](../Docs/PackageManagement.md) for the complete schema.

## Packages

`packages/*.toml` defines one logical package per file and maps it to supported platform/provider targets. Profiles refer to the logical package name, not a provider-specific identifier.

## KDE Profiles

`KDEProfiles/*.knsv` contains Konsave exports. Use `Tools/save_konsave_profile.py` to create or synchronize them.
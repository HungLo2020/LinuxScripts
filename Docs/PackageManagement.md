# Package Management

`Tools/manage_packages.py` plans and installs named package profiles from TOML resources.

## Commands

```bash
python3 Tools/manage_packages.py profiles
python3 Tools/manage_packages.py plan complete-desktop
python3 Tools/manage_packages.py plan complete-desktop --platform windows
python3 Tools/manage_packages.py apply complete-desktop --yes
```

`plan` never changes the host. `apply` prints the same plan and requires `--yes` before it executes provider commands.

## Resources

- `resources/profiles/*.toml` defines named profiles.
- `resources/packages/*.toml` maps one logical package per file to platform and provider targets.

Profiles can depend on other profiles:

```toml
[profile]
name = "complete-desktop"
includes = ["desktop", "coding", "gaming", "office"]
required_packages = []
optional_packages = []

[platforms.linux]
required_packages = ["flatpak", "konsave"]
optional_packages = []
```

Packages can have global dependencies, and each target can add dependencies that apply only to that platform/provider:

```toml
[package]
name = "discord"
depends_on = []

[targets.linux.flatpak]
id = "com.discordapp.Discord"
remote = "flathub"
depends_on = ["flatpak"]

[targets.windows.winget]
id = "Discord.Discord"
```

Each profile and platform table has `required_packages` and `optional_packages` arrays. A package cannot appear in both arrays within the same table. The resolver expands profile includes, adds common packages and packages from the matching `[platforms.<os>]` table, selects a target for the requested platform, resolves package dependencies before dependents, removes duplicates, and rejects profile or package cycles. Platform-specific profile packages are not requested on other operating systems. Required packages with no compatible target fail the plan. Optional packages are listed as skipped; the resolver never substitutes an incompatible native Linux package manager.

Profiles can run repository Python dependency scripts before their packages are installed:

```toml
[profile]
script_dependencies = ["hello_world.py"]
```

Packages can run dependency scripts immediately before or after that individual package's provider operation:

```toml
[script_dependencies]
before = ["hello_world.py"]
after = []
```

Script paths are relative to `src/scripts/`. They are shown by `plan`, then run only during `apply --yes` with the project Python interpreter. Package installs without hooks remain batched; a package with hooks gets its own provider operation so its declared order is preserved.

`utilities` is a shared profile included by both `desktop` and `server`. Its current package list is Linux-only, so it contributes no packages to Windows, macOS, or MattOS. `auth` is also included by `desktop` and `server`, and installs Bitwarden plus the `bw` command-line client on every supported platform.

## MattOS

MattOS is detected when its `/etc/os-release` declares `ID=mattos`. It is an APT-based platform, but it does not inherit generic Linux profile sections or package targets. Every MattOS-specific profile package and package target must be declared explicitly.

```toml
[platforms.mattos]
required_packages = ["mattos-control-center"]
optional_packages = []
```

```toml
[targets.mattos.apt]
id = "mattos-control-center"
```

Declare only the provider targets that actually distribute a package. For example, a MattOS APT-only package needs only `[targets.mattos.apt]`; it must not include placeholder DNF, Pacman, or generic Linux targets. Likewise, `[platforms.linux]` entries do not apply on MattOS. If a required package is requested with an incompatible native package manager, planning fails clearly, for example: `Package 'basalt' is not available for the dnf package manager on mattos.`

Use `python3 Tools/manage_packages.py plan complete-desktop --platform mattos` to preview a MattOS plan on another machine. A MattOS host selects this platform automatically.

## Providers

The initial providers are APT, DNF, Pacman, Zypper, APK, Flatpak, pipx, Snap, Winget, and Homebrew. Native Linux provider selection uses `src/system.py` to read the distro and available package manager.

Provider logic is responsible only for translating resolved targets into commands. `src/packages/executor.py` performs those commands after explicit CLI confirmation. Profiles never contain shell commands, installer URLs, or privilege logic.

## Python 3.10

Python 3.11 includes `tomllib`. On Python 3.10, Bootstrap installs the conditional `tomli` dependency from `requirements.txt` into the project virtual environment.
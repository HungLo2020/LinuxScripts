# Tools

User-facing Python entry points. Run these from the repository root with the project virtual environment available.

## Setup

`Setup.py` is the primary package-management entry point. With no arguments, it displays detected host details, presents a numbered profile menu, prints the selected plan, and asks for confirmation before applying it:

```bash
python3 Tools/Setup.py
```

After a successful interactive apply on Linux with APT, it also offers persistent Tailscale SMB storage-mount setup. The service retries indefinitely when Tailscale or the server share is unavailable; see [../Docs/PackageManagement.md](../Docs/PackageManagement.md) for its defaults and credential behavior.

It also forwards non-interactive commands to the implementation in `src/packages/cli.py`:

```bash
python3 Tools/Setup.py profiles
python3 Tools/Setup.py plan complete-desktop
python3 Tools/Setup.py apply complete-desktop --yes
```

See [../Docs/PackageManagement.md](../Docs/PackageManagement.md) for profile schema, providers, and platform behavior.

## KDE Profiles

`save_konsave_profile.py` exports the active KDE configuration to `resources/KDEProfiles/`. It can optionally synchronize exports to GitHub Releases:

```bash
python3 Tools/save_konsave_profile.py --name MyProfile --no-upload
python3 Tools/save_konsave_profile.py --name MyProfile --upload
```

The save tool currently runs the Konsave setup helper still located under `Deprecated/`; that helper has not yet been migrated into the active tooling.
# Server Management

Run the Linux-only server administration interface with:

```bash
python3 Tools/ServerManager.py
```

The Btrfs Snapshot Manager elevates independently because it manages Btrfs subvolumes. Container and Restic management intentionally run as the invoking user, preserving user-owned service data and configuration.

## Restic Backups

The Restic capability is a Python replacement for the legacy manager. It retains the legacy defaults, persisted configuration paths, command-line interface, helper names, and systemd unit names:

```text
Source:     /srv/storage/Storage/Sync/MattMC
Repository: /srv/storage/OneDrive/Apps/Games/Storage/MattMC/Restic
Config root: ~/.config/restic-mattmc
```

It supports multiple named configurations, setup/rerun, immediate backup, snapshot listing with approximate size, restore to `~/Downloads`, manual retention pruning, status display, and deletion of a config/service/timer. A configured job has a daily persistent systemd timer with up to a 30-minute random delay and retention of 7 daily, 4 weekly, 12 monthly, and 2 yearly snapshots.

Restic reads existing shell-style `.env` configuration files from the legacy manager and imports the older single `backup.env` configuration as `MattMC` when required. It operates on source and repository paths accessible from the machine running the manager; it does not remotely execute backups over SSH or Tailscale.
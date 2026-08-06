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

## ZIP Backups

The ZIP capability replaces the legacy ZIP backup manager and retains its configuration root, defaults, helper/unit names, menus, and command aliases:

```text
Source:      /srv/storage/Storage/Sync/MattMC
Destination: /srv/storage/OneDrive/Apps/Games/Storage/MattMC/AutoZipArchives
Config root: ~/.config/zip-backup-manager
```

Each run creates `prefix_YYYY-MM-DD_HH-MM-SS.zip`, validates it with `unzip -tqq`, and writes a `.sha256` sidecar when `sha256sum` is available. Retention preserves the newest archive across the newest 3 daily, 3 ISO-weekly, 3 monthly, and 2 yearly buckets. It removes only archives matching that exact managed naming pattern and removes their checksum sidecars alongside them.

The manager supports multiple configurations, setup/rerun, immediate archive creation, archive listing, manual pruning, unit triggering, status display, and safe configuration deletion. A job runs through a daily persistent systemd timer with up to 30 minutes of randomized delay as the user who created it. If a destination is shared by another configuration, deletion preserves the destination and its archives.

## Uptime Kuma

Server Manager can optionally run the legacy-compatible Uptime Kuma container workload. The direct launcher is:

```bash
python3 src/containers/run_uptime_kuma.py
```

It preserves the no-argument install/update/start behavior and `--on`, `--off`, and `-D` lifecycle flags. The container is named `uptime-kuma`, uses `louislam/uptime-kuma:latest`, persists data at `~/.uptime-kuma/data`, and serves the UI at `http://localhost:3002` by default. Set `UPTIME_KUMA_PORT` before running it to select another host port.
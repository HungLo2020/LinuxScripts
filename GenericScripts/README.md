# Generic Scripts

Standalone utilities that can be used independently of package profiles.

## Generic Backup

`GenericBackup.sh` creates a timestamped ZIP archive. Edit `DIR_TO_BACKUP` and `DIR_TO_BACKUP_TO` in the script before running it. It excludes `node_modules`, `*.tmp`, and `.git`, writes the archive to `/tmp`, then moves it to the configured destination.

## MattOS Repository Manager

`ManageMattOSRepository.py` is the compatibility client for the locally hosted,
signed MattOS Debian repository. It does not build `.deb` packages; it sends
packages to the home-server repository service, which runs `reprepro` and
publishes the repository.

```bash
python3 GenericScripts/ManageMattOSRepository.py doctor
python3 GenericScripts/ManageMattOSRepository.py status
python3 GenericScripts/ManageMattOSRepository.py upload /absolute/path/package.deb
```

Configure clients with:

```bash
export MATTOS_REPOSITORY_SERVER_URL=https://repo-api.example
export MATTOS_REPOSITORY_URL=https://repo.example/repository
export MATTOS_REPOSITORY_TOKEN_FILE=$HOME/.config/mattos-repository/token
```

The token file must contain the credential created by the server's `token`
command. The client has no Cloudflare, R2, boto3, or Bitwarden dependency.

On the home server, initialize and run the separate server manager:

```bash
python3 Tools/ManageMattOSRepositoryServer.py init
python3 Tools/ManageMattOSRepositoryServer.py token
python3 Tools/ManageMattOSRepositoryServer.py serve --bind 127.0.0.1
```

The service itself serves `/repository/` from the active release. A reverse
proxy is optional if HTTPS or a custom hostname is needed. Keep the mutation
API private behind Tailscale, a VPN, or an authenticated reverse proxy.

Server setup also installs Cloudflare's `cloudflared` package and creates its
systemd service when a tunnel token is supplied. The Cloudflare dashboard still
must create the tunnel and hostname route; see `Docs/ServerManagement.md`.

# Generic Scripts

Standalone utilities that can be used independently of package profiles.

## Generic Backup

`GenericBackup.sh` creates a timestamped ZIP archive. Edit `DIR_TO_BACKUP` and `DIR_TO_BACKUP_TO` in the script before running it. It excludes `node_modules`, `*.tmp`, and `.git`, writes the archive to `/tmp`, then moves it to the configured destination.

## MattOS Repository Manager

`ManageMattOSRepository.py` manages a signed Debian repository published through Cloudflare R2. It does not build `.deb` packages.

```bash
python3 GenericScripts/ManageMattOSRepository.py doctor
python3 GenericScripts/ManageMattOSRepository.py status
python3 GenericScripts/ManageMattOSRepository.py upload /absolute/path/package.deb
```

Use `doctor` before mutating commands. The tool uses Bitwarden for R2 credentials and the repository signing key, and creates a tool-owned virtual environment for Python dependencies.
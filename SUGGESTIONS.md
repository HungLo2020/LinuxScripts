# Project Ideas & Suggestions

This document contains ideas for improving and extending **LinuxScripts** — a personal Linux setup automation toolkit for KDE Plasma on Ubuntu/Debian-based systems.

---

## Bug Fixes

### 1. Missing `contains_exact` Function in `SetupLinux.sh`

`SetupLinux.sh` calls `contains_exact` (lines 98, 133, 136) inside `apply_script_order`, but the function is never defined in that file. This will cause a runtime error any time `script-order.txt` is present and `apply_script_order` is invoked. The function needs to be defined in `SetupLinux.sh` directly.

**Fix:** Add this near the top of `SetupLinux.sh`, before `apply_script_order`:

```bash
contains_exact() {
  local needle="$1"
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}
```

### 2. Typo in `InstallFlatpakPackages.sh`

Line: `sudi flatpak install -y flathub com.discordapp.Discord`

`sudi` should be `sudo`. This will silently fail or throw a "command not found" error, leaving Discord uninstalled.

---

## Quality & Robustness

### 3. ShellCheck CI Pipeline

Add a GitHub Actions workflow that runs [ShellCheck](https://www.shellcheck.net/) across all `.sh` files on every push and pull request. This would catch bugs like the ones above automatically.

```yaml
# .github/workflows/shellcheck.yml
name: ShellCheck
on: [push, pull_request]
jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run ShellCheck
        run: find . -name "*.sh" | xargs shellcheck
```

### 4. Idempotency: Skip Already-Installed Packages

Most install scripts blindly re-run `apt install` every time. Add a check so already-installed packages are skipped with a friendly message, making reruns safe and fast.

```bash
for package in "${packages[@]}"; do
  if dpkg -s "$package" >/dev/null 2>&1; then
    echo "Already installed: $package"
  else
    sudo apt install -y "$package"
    echo "Installed: $package"
  fi
done
```

### 5. Dry-Run Mode

Add a `--dry-run` flag to `SetupLinux.sh`. When set, the script prints every action it *would* take — packages to install, scripts to run, configs to modify — without touching the system. Invaluable for reviewing a setup before committing.

```bash
# Usage:
./SetupLinux.sh --dry-run
```

### 6. Structured Logging to a File

Pipe all output to a timestamped log file (e.g., `~/setup-2025-01-01.log`) in addition to stdout. This lets users review exactly what happened after a long setup run, especially useful when something goes wrong.

---

## Usability

### 7. Interactive TUI Menu with `whiptail`

Replace the chain of `y/n` readline prompts with a multi-select checklist using `whiptail` (available on all Ubuntu installs). Users could see all available scripts at once, check/uncheck them, and confirm with a single key press.

```bash
whiptail --title "Select Setup Scripts" --checklist "Choose:" 20 60 10 \
  "InstallDevUtils" "Development tools" ON \
  "InstallGamePackages" "Steam, RetroArch" OFF \
  ...
```

### 8. Script Categories in the Menu

Group scripts by category (System, Dev, Gaming, Office, Remote Access, etc.) so the menu is easier to navigate, especially as more scripts are added.

### 9. Unattended/Profile Mode

Add preset profiles that can be run non-interactively:

```bash
./SetupLinux.sh --profile minimal    # core packages only
./SetupLinux.sh --profile developer  # + dev tools, git repos
./SetupLinux.sh --profile full       # everything
```

Profiles could be defined as simple text files listing which scripts to enable.

### 10. Post-Install Summary Report

At the end of a run, print a summary table showing which scripts succeeded, which were skipped, and which failed — with total elapsed time.

```
=== Setup Summary ===
✅ AddRepos                  (0:03)
✅ InstallDefaultPackages    (1:42)
⚠️  InstallGamePackages      skipped (user declined)
❌ NVIDIADrivers             failed (see log)
Total time: 4:17
```

---

## Extensibility & Configuration

### 11. Central Package Config File

Move hardcoded package lists out of each script and into a central `resources/packages.conf` (or `packages.yaml`). This makes customizing the package selection trivial — just edit one file without touching the logic.

```ini
[default]
rclone kate konsole dolphin fastfetch flatpak pipx

[dev]
cura virt-manager gh

[gaming]
steam retroarch
```

### 12. Dotfiles Management Script

Add a script that symlinks or copies personal dotfiles (`.bashrc`, `.bash_aliases`, `.gitconfig`, shell prompt configs, etc.) from a folder in the repo. Combine well with [GNU Stow](https://www.gnu.org/software/stow/) for zero-boilerplate dotfile management.

### 13. Multi-Distro Support

Abstract the package manager behind a thin wrapper so the same scripts work on Fedora (`dnf`) and Arch (`pacman`) in addition to Ubuntu (`apt`). A small `lib/pkgmgr.sh` with `install_package`, `remove_package`, and `is_installed` functions would make this clean.

### 14. Plug-in Architecture for New Scripts

Formalise the naming/metadata convention for scripts. For example, require each setup script to expose a `SCRIPT_DESCRIPTION` variable at the top. `SetupLinux.sh` could read this variable to display a human-friendly label in the menu instead of just the filename.

```bash
# At the top of each script:
SCRIPT_DESCRIPTION="Install gaming packages (Steam, RetroArch)"
```

---

## KDE Plasma / Desktop

### 15. KDE Theme & Color Scheme Script

Add a script that applies a preferred KDE global theme, color scheme, icon pack, and cursor theme non-interactively using `lookandfeeltool` and `plasma-apply-colorscheme`. This would give the desktop a consistent look instantly after setup.

### 16. Font Installation Script

Add a script that installs preferred system fonts (e.g., JetBrains Mono, Nerd Fonts, Google Fonts) and registers them with `fc-cache`.

### 17. KDE Keyboard Shortcuts Script

Add a script that exports and imports custom KDE keyboard shortcuts using `kwriteconfig6`, so hotkeys survive a fresh install.

---

## Backup & Sync

### 18. Incremental Backup with `rsync`

`BackupLinuxScripts.sh` currently creates a full zip every time. Consider an `rsync`-based approach for incremental backups that only copy changed files — much faster and storage-efficient over time.

### 19. Backup Rotation / Retention Policy

Add a cleanup step to `BackupLinuxScripts.sh` that removes zip archives older than N days, preventing the backup destination from filling up.

### 20. Restore Script

Complement the backup workflow with a `RestoreLinuxScripts.sh` that can unzip a previously created backup and put files back in the right place — turning the backup from write-only to actually useful.

---

## Remote Access & Networking

### 21. WireGuard VPN Setup Script

Add a script to configure a WireGuard VPN alongside or instead of Tailscale, for users who prefer a self-hosted VPN solution.

### 22. SSH Key Generation & GitHub Registration

Add a script that generates an SSH key pair (if none exists), prints the public key, and optionally registers it with GitHub via the `gh` CLI — removing a common manual step after a fresh install.

```bash
ssh-keygen -t ed25519 -C "$USER@$(hostname)" -f ~/.ssh/id_ed25519
gh ssh-key add ~/.ssh/id_ed25519.pub --title "$(hostname)"
```

---

## Documentation

### 23. README Improvements

The current `README.md` is empty. At minimum it would help to document:
- Prerequisites (Ubuntu/KDE Plasma, sudo access, internet)
- Quick-start: `git clone … && chmod +x SetupLinux.sh && ./SetupLinux.sh`
- Directory structure overview
- How to add a new setup script
- How to customise `script-order.txt`

### 24. Per-Script Header Comments

Add a brief comment block at the top of each script explaining what it does, any prerequisites, and side effects. Makes the repo easier to understand for others (and for future-you).

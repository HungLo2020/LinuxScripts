#!/usr/bin/env python3
"""
Manage the MattOS Debian package repository published through Cloudflare R2.

This script manages repository publication, not package creation. A separate
project can build one or more .deb files and then hand them to this script.

Cloudflare/R2 prerequisites
---------------------------
1. Create an R2 bucket and connect its public custom domain. The defaults in
   this script are:

       bucket:     matt-apt-repo
       public URL: https://packages.mattsherfey.com

2. Create a bucket-scoped R2 Object Read & Write credential and save it in the
   Bitwarden Login item named "MattOS R2 Repository Publisher". The Login
   username must be the R2 Access Key ID and the password must be the R2 Secret
   Access Key. Add these custom fields:

       R2_ENDPOINT       https://<account-id>.r2.cloudflarestorage.com
       R2_BUCKET_NAME    matt-apt-repo
       R2_PUBLIC_URL     https://packages.mattsherfey.com

3. The first `init` automatically creates a dedicated repository signing key
   if the Bitwarden Secure Note named "MattOS Repository Signing Key" does not
   exist. It stores the ASCII-armored private key in that note and uses the key
   from a temporary GPG home. No manual key creation is required. If the note
   already exists, the script uses its PRIVATE_KEY custom field or note body.

4. Install/use the Bitwarden CLI before running commands. The script first
   reuses a valid BW_SESSION when one is present. If no valid session exists,
   it looks for the current user's password file at
   `~/Documents/Repos/LinuxScripts/.bw_master_password`. If that file is
   missing or its password does not work, the script securely prompts for the
   Bitwarden master password. It never writes the password to the repository.

   The Bitwarden CLI must already be installed. If `bw` is missing, the script
   stops with a clear installation message; it does not silently install or
   modify Bitwarden.

First-time setup
----------------
Run `init` once after the R2 bucket and R2 Bitwarden item exist. If the signing
key item is missing, `init` creates the dedicated key and Secure Note
automatically. It then creates the initial signed trixie/main repository and
publishes its metadata to R2. It does not create or build any packages.

Normal package workflow
-----------------------
    python3 ManageMattOSRepository.py doctor
    python3 ManageMattOSRepository.py add ./build/*.deb
    python3 ManageMattOSRepository.py list
    python3 ManageMattOSRepository.py verify

`add` and `remove` publish automatically. `publish` rebuilds and republishes
the current remote package set. `export-key` writes the public signing key
for installation on MattOS/Debian clients. `export-private-key` exists for
explicit operational recovery only and requires an output path.

Repository details
------------------
The repository suite is `trixie` (Debian 13) and the component is `main`.
R2 is the persistent source of truth. Each mutating command downloads the
current published package set into a temporary directory, runs reprepro, then
uploads only changed/new/deleted public objects. The temporary directory is
removed on exit. No repository database or package copy is kept permanently
on the machine running this script.

Environment overrides
---------------------
MATTOS_R2_ITEM                 Bitwarden item name for R2 credentials
MATTOS_GPG_ITEM                Bitwarden item name for signing key
MATTOS_R2_BUCKET               R2 bucket name
MATTOS_R2_ENDPOINT              R2 S3 endpoint
MATTOS_REPOSITORY_URL           Public repository URL
MATTOS_REPOSITORY_SUITE         Repository suite (default: trixie)
MATTOS_REPOSITORY_COMPONENT     Repository component (default: main)
MATTOS_REPOSITORY_ARCHITECTURES Comma-separated architectures (default: amd64,all)
MATTOS_GPG_PRIVATE_KEY_FILE     Optional local private-key file override
MATTOS_GPG_PASSPHRASE_FILE      Optional local passphrase-file override

This script intentionally does not commit generated repository files, R2
credentials, GPG keys, or package artifacts to Git.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


DEFAULT_R2_ITEM = "MattOS R2 Repository Publisher"
DEFAULT_GPG_ITEM = "MattOS Repository Signing Key"
DEFAULT_BUCKET = "matt-apt-repo"
DEFAULT_PUBLIC_URL = "https://packages.mattsherfey.com"
DEFAULT_SUITE = "trixie"
DEFAULT_COMPONENT = "main"
DEFAULT_ARCHITECTURES = ("amd64", "all")
BITWARDEN_PASSWORD_FILE = (
    Path.home() / "Documents" / "Repos" / "LinuxScripts" / ".bw_master_password"
)


class RepositoryError(RuntimeError):
    """A user-facing repository operation failure."""


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def run_command(
    args: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: Path | None = None,
    input_text: str | None = None,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            args,
            cwd=str(cwd) if cwd else None,
            env=env,
            input=input_text,
            text=True,
            capture_output=capture,
            check=False,
        )
    except FileNotFoundError as exc:
        raise RepositoryError(f"Required command not found: {args[0]}") from exc
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise RepositoryError(
            f"Command failed ({result.returncode}): {' '.join(args)}"
            + (f"\n{detail}" if detail else "")
        )
    return result


def ensure_reprepro() -> None:
    if command_exists("reprepro"):
        return

    print("reprepro is not installed; installing it with apt...")
    if os.geteuid() == 0:
        prefix: list[str] = []
    elif command_exists("sudo"):
        prefix = ["sudo"]
    else:
        raise RepositoryError("reprepro is missing and sudo is unavailable")

    run_command(prefix + ["apt-get", "update"], capture=False)
    run_command(prefix + ["apt-get", "install", "-y", "reprepro"], capture=False)


def ensure_boto3() -> Any:
    try:
        import boto3  # type: ignore

        return boto3
    except ImportError as exc:
        raise RepositoryError(
            "Python package boto3 is required. Install it with "
            "'python3 -m pip install --user boto3' or use your project "
            "environment, then rerun this command."
        ) from exc


def bitwarden_status() -> str:
    result = run_command(["bw", "status", "--raw"], check=False)
    if result.returncode != 0:
        return "unknown"
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return "unknown"
    return str(payload.get("status", "unknown"))


def try_bitwarden_unlock(password: str) -> bool:
    if not password:
        return False
    env = os.environ.copy()
    env["BW_MASTER_PASSWORD"] = password
    result = run_command(
        [
            "bw",
            "unlock",
            "--passwordenv",
            "BW_MASTER_PASSWORD",
            "--nointeraction",
            "--raw",
        ],
        env=env,
        check=False,
    )
    if result.returncode != 0:
        return False
    session = result.stdout.strip()
    if not session:
        return False
    os.environ["BW_SESSION"] = session
    return True


def ensure_bitwarden_session() -> None:
    if not command_exists("bw"):
        raise RepositoryError(
            "Bitwarden CLI (bw) is required but is not installed. Install the "
            "Bitwarden CLI, ensure the 'bw' command is in PATH, then rerun "
            "this command."
        )

    if bitwarden_status() == "unlocked":
        return

    if BITWARDEN_PASSWORD_FILE.is_file():
        stored_password = BITWARDEN_PASSWORD_FILE.read_text(encoding="utf-8").rstrip("\n")
        if try_bitwarden_unlock(stored_password):
            return
        print(
            f"Could not unlock Bitwarden using {BITWARDEN_PASSWORD_FILE}; "
            "falling back to a password prompt.",
            file=sys.stderr,
        )

    try:
        password = getpass.getpass("Bitwarden master password: ")
    except (EOFError, KeyboardInterrupt) as exc:
        raise RepositoryError("Bitwarden unlock was cancelled") from exc
    if not try_bitwarden_unlock(password):
        raise RepositoryError("Bitwarden unlock failed; check the master password")


def bitwarden_item(name: str, *, required: bool = True) -> dict[str, Any] | None:
    ensure_bitwarden_session()

    result = run_command(["bw", "get", "item", name, "--raw"], check=False)
    if result.returncode != 0:
        if not required:
            return None
        detail = (result.stderr or result.stdout or "").strip()
        raise RepositoryError(
            f"Bitwarden item {name!r} could not be read"
            + (f": {detail}" if detail else "")
        )
    try:
        item = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RepositoryError(
            "Bitwarden did not return item JSON. Unlock Bitwarden and ensure "
            "BW_SESSION is set."
        ) from exc
    if not isinstance(item, dict):
        raise RepositoryError(f"Bitwarden item {name!r} has an invalid shape")
    return item


def custom_fields(item: dict[str, Any]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for field in item.get("fields") or []:
        if not isinstance(field, dict):
            continue
        name = field.get("name")
        value = field.get("value")
        if isinstance(name, str) and value is not None:
            fields[name] = str(value)
    return fields


def get_r2_credentials() -> tuple[str, str, str, str, str]:
    item = bitwarden_item(os.environ.get("MATTOS_R2_ITEM", DEFAULT_R2_ITEM))
    assert item is not None
    login = item.get("login") or {}
    username = str(login.get("username") or "").strip()
    password = str(login.get("password") or "")
    fields = custom_fields(item)
    endpoint = os.environ.get("MATTOS_R2_ENDPOINT", fields.get("R2_ENDPOINT", "")).strip()
    bucket = os.environ.get("MATTOS_R2_BUCKET", fields.get("R2_BUCKET_NAME", DEFAULT_BUCKET)).strip()
    public_url = os.environ.get(
        "MATTOS_REPOSITORY_URL",
        fields.get("R2_PUBLIC_URL", DEFAULT_PUBLIC_URL),
    ).rstrip("/")

    missing = []
    if not username:
        missing.append("Login username / Access Key ID")
    if not password:
        missing.append("Login password / Secret Access Key")
    if not endpoint:
        missing.append("R2_ENDPOINT custom field")
    if not bucket:
        missing.append("R2_BUCKET_NAME custom field")
    if missing:
        raise RepositoryError(
            "R2 Bitwarden item is missing: " + ", ".join(missing)
        )
    return username, password, endpoint, bucket, public_url


def create_signing_key_item() -> tuple[str, str | None]:
    if not command_exists("gpg"):
        raise RepositoryError("gpg is required to create the MattOS repository signing key")

    print("No MattOS repository signing key exists in Bitwarden; creating one now...")
    with tempfile.TemporaryDirectory(prefix="mattos-key-bootstrap-") as temporary:
        root = Path(temporary)
        gpg_home = root / "gnupg"
        gpg_home.mkdir(mode=0o700)
        env = os.environ.copy()
        env["GNUPGHOME"] = str(gpg_home)
        identity = "MattOS Repository Signing Key <packages@mattsherfey.com>"
        run_command(
            [
                "gpg",
                "--batch",
                "--pinentry-mode",
                "loopback",
                "--passphrase",
                "",
                "--quick-gen-key",
                identity,
                "rsa4096",
                "sign",
                "3y",
            ],
            env=env,
        )
        fingerprint_result = run_command(
            ["gpg", "--batch", "--with-colons", "--list-secret-keys"], env=env
        )
        fingerprint = ""
        for line in fingerprint_result.stdout.splitlines():
            parts = line.split(":")
            if len(parts) > 9 and parts[0] == "fpr":
                fingerprint = parts[9]
                break
        if not fingerprint:
            raise RepositoryError("The generated signing key fingerprint could not be found")
        private_key = run_command(
            ["gpg", "--batch", "--armor", "--export-secret-keys", fingerprint], env=env
        ).stdout

    item_name = os.environ.get("MATTOS_GPG_ITEM", DEFAULT_GPG_ITEM)
    item = {
        "type": 2,
        "secureNote": {"type": 0},
        "name": item_name,
        "notes": private_key,
        "fields": [],
    }
    encoded = run_command(
        ["bw", "encode"], input_text=json.dumps(item)
    ).stdout.strip()
    run_command(["bw", "create", "item", encoded])
    print(f"Created Bitwarden Secure Note: {item_name}")
    return private_key, None


def get_gpg_material(*, allow_bootstrap: bool = False) -> tuple[str, str | None]:
    key_file = os.environ.get("MATTOS_GPG_PRIVATE_KEY_FILE")
    pass_file = os.environ.get("MATTOS_GPG_PASSPHRASE_FILE")
    if key_file:
        key_path = Path(key_file).expanduser()
        if not key_path.is_file():
            raise RepositoryError(f"GPG private-key file not found: {key_path}")
        key_text = key_path.read_text(encoding="utf-8")
        passphrase = Path(pass_file).read_text(encoding="utf-8") if pass_file else None
        return key_text, passphrase.rstrip("\n") if passphrase else None

    item = bitwarden_item(
        os.environ.get("MATTOS_GPG_ITEM", DEFAULT_GPG_ITEM),
        required=False,
    )
    if item is None:
        if allow_bootstrap:
            return create_signing_key_item()
        raise RepositoryError(
            "The MattOS repository signing-key Bitwarden item does not exist. "
            "Run 'init' once to create it automatically."
        )
    fields = custom_fields(item)
    notes = item.get("notes") or ""
    key_text = fields.get("PRIVATE_KEY", "") or str(notes)
    passphrase = fields.get("PASSPHRASE")
    if "BEGIN PGP PRIVATE KEY BLOCK" not in key_text:
        raise RepositoryError(
            f"Bitwarden item {os.environ.get('MATTOS_GPG_ITEM', DEFAULT_GPG_ITEM)!r} "
            "does not contain an ASCII-armored private key. Add it to the "
            "note body or a PRIVATE_KEY custom field."
        )
    return key_text, passphrase


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def file_map(root: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for top in ("dists", "pool"):
        directory = root / top
        if not directory.exists():
            continue
        for path in directory.rglob("*"):
            if path.is_file():
                result[path.relative_to(root).as_posix()] = path
    return result


@dataclass(frozen=True)
class Settings:
    suite: str
    component: str
    architectures: tuple[str, ...]
    r2_item: str
    gpg_item: str
    bucket: str
    endpoint: str
    public_url: str


def settings_from_environment() -> Settings:
    architectures = tuple(
        item.strip()
        for item in os.environ.get(
            "MATTOS_REPOSITORY_ARCHITECTURES", ",".join(DEFAULT_ARCHITECTURES)
        ).split(",")
        if item.strip()
    )
    return Settings(
        suite=os.environ.get("MATTOS_REPOSITORY_SUITE", DEFAULT_SUITE),
        component=os.environ.get("MATTOS_REPOSITORY_COMPONENT", DEFAULT_COMPONENT),
        architectures=architectures,
        r2_item=os.environ.get("MATTOS_R2_ITEM", DEFAULT_R2_ITEM),
        gpg_item=os.environ.get("MATTOS_GPG_ITEM", DEFAULT_GPG_ITEM),
        bucket="",
        endpoint="",
        public_url="",
    )


def r2_client(settings: Settings) -> tuple[Any, Settings]:
    boto3 = ensure_boto3()
    access_key, secret_key, endpoint, bucket, public_url = get_r2_credentials()
    client = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="auto",
    )
    return client, Settings(
        suite=settings.suite,
        component=settings.component,
        architectures=settings.architectures,
        r2_item=settings.r2_item,
        gpg_item=settings.gpg_item,
        bucket=bucket,
        endpoint=endpoint,
        public_url=public_url,
    )


def list_remote_keys(client: Any, bucket: str) -> list[str]:
    keys: list[str] = []
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket):
        for entry in page.get("Contents", []):
            key = entry.get("Key")
            if isinstance(key, str) and (key.startswith("dists/") or key.startswith("pool/")):
                keys.append(key)
    return keys


def download_remote_repository(client: Any, bucket: str, root: Path) -> set[str]:
    keys = set(list_remote_keys(client, bucket))
    for key in sorted(keys):
        destination = root / key
        destination.parent.mkdir(parents=True, exist_ok=True)
        client.download_file(bucket, key, str(destination))
    return keys


def create_gpg_home(root: Path, key_text: str, passphrase: str | None) -> tuple[Path, str]:
    gpg_home = root / "gnupg"
    gpg_home.mkdir(mode=0o700)
    env = os.environ.copy()
    env["GNUPGHOME"] = str(gpg_home)
    run_command(["gpg", "--batch", "--import"], env=env, input_text=key_text)
    result = run_command(
        ["gpg", "--batch", "--with-colons", "--list-secret-keys"], env=env
    )
    fingerprint = ""
    for line in result.stdout.splitlines():
        parts = line.split(":")
        if len(parts) > 9 and parts[0] == "fpr":
            fingerprint = parts[9]
            break
    if not fingerprint:
        raise RepositoryError("No secret GPG key was found in the signing-key material")

    # reprepro invokes gpg itself. An encrypted key requires an already
    # configured gpg-agent/pinentry workflow. The script supports passphrases
    # for explicit export, but publishing requires a non-interactive signing
    # key or an agent that can answer signing requests.
    if passphrase:
        print(
            "Warning: the signing key is passphrase-protected. Reprepro must "
            "be able to use it non-interactively through gpg-agent."
        )
    return gpg_home, fingerprint


def write_reprepro_config(root: Path, settings: Settings, fingerprint: str) -> None:
    conf = root / "conf"
    conf.mkdir(parents=True, exist_ok=True)
    distributions = """Origin: MattOS
Label: MattOS
Codename: {suite}
Suite: {suite}
Architectures: {architectures}
Components: {component}
Description: MattOS packages compatible with Debian 13 Trixie
SignWith: {fingerprint}
DebIndices: Packages Release . .gz
Contents: .gz
""".format(
        suite=settings.suite,
        architectures=" ".join(settings.architectures),
        component=settings.component,
        fingerprint=fingerprint,
    )
    (conf / "distributions").write_text(distributions, encoding="utf-8")


def package_metadata(path: Path) -> tuple[str, str, str]:
    if not command_exists("dpkg-deb"):
        raise RepositoryError("dpkg-deb is required to inspect Debian packages")
    result = run_command(
        ["dpkg-deb", "-f", str(path), "Package", "Version", "Architecture"]
    )
    values = result.stdout.splitlines()
    if len(values) != 3 or not all(values):
        raise RepositoryError(f"Could not read package metadata from {path}")
    return values[0].strip(), values[1].strip(), values[2].strip()


def include_packages(root: Path, settings: Settings, packages: Iterable[Path]) -> None:
    for package in sorted(packages):
        package_name, version, architecture = package_metadata(package)
        if architecture not in settings.architectures:
            raise RepositoryError(
                f"{package.name} targets architecture {architecture!r}, but configured "
                f"architectures are {', '.join(settings.architectures)}"
            )
        print(f"Including {package_name} {version} ({architecture})")
        run_command(
            ["reprepro", "--basedir", str(root), "includedeb", settings.suite, str(package)]
        )


def build_repository(
    root: Path,
    settings: Settings,
    key_text: str,
    passphrase: str | None,
    packages: Iterable[Path],
) -> None:
    gpg_home, fingerprint = create_gpg_home(root, key_text, passphrase)
    env = os.environ.copy()
    env["GNUPGHOME"] = str(gpg_home)
    write_reprepro_config(root, settings, fingerprint)
    include_packages(root, settings, packages)
    run_command(["reprepro", "--basedir", str(root), "export"], env=env)


def publish_diff(client: Any, bucket: str, root: Path, old_keys: set[str]) -> None:
    local = file_map(root)
    new_keys = set(local)

    for key in sorted(old_keys - new_keys):
        print(f"Deleting s3://{bucket}/{key}")
        client.delete_object(Bucket=bucket, Key=key)

    for key in sorted(new_keys):
        path = local[key]
        digest = sha256_file(path)
        if key in old_keys:
            try:
                head = client.head_object(Bucket=bucket, Key=key)
                if head.get("Metadata", {}).get("sha256") == digest:
                    continue
                if head.get("ContentLength") == path.stat().st_size:
                    # Objects created by this script carry a digest. For older
                    # or manually uploaded objects, compare bytes before replacing.
                    existing = root / ".remote-compare" / key
                    existing.parent.mkdir(parents=True, exist_ok=True)
                    client.download_file(bucket, key, str(existing))
                    if sha256_file(existing) == digest:
                        continue
            except Exception as exc:
                error_code = getattr(exc, "response", {}).get("Error", {}).get("Code")
                if str(error_code) not in {"404", "NoSuchKey", "NotFound"}:
                    raise

        content_type = "application/octet-stream"
        cache_control = "public, max-age=31536000, immutable"
        if key.startswith("dists/"):
            content_type = "text/plain; charset=utf-8"
            cache_control = "no-cache, max-age=0, must-revalidate"
        elif key.endswith(".gz"):
            content_type = "application/gzip"
        elif key.endswith(".deb"):
            content_type = "application/vnd.debian.binary-package"
        print(f"Uploading {key}")
        client.upload_file(
            str(path),
            bucket,
            key,
            ExtraArgs={
                "ContentType": content_type,
                "CacheControl": cache_control,
                "Metadata": {"sha256": digest},
            },
        )


def with_repository_workspace(
    settings: Settings,
    action: str,
    package_paths: list[Path] | None = None,
    remove_name: str | None = None,
    remove_version: str | None = None,
) -> None:
    client, settings = r2_client(settings)
    with tempfile.TemporaryDirectory(prefix="mattos-repo-") as temporary:
        root = Path(temporary) / "repository"
        root.mkdir()
        old_keys = download_remote_repository(client, settings.bucket, root)
        if action == "init" and old_keys:
            key_text, passphrase = get_gpg_material()
        else:
            key_text, passphrase = get_gpg_material(allow_bootstrap=action == "init")
        existing_packages = [path for path in (root / "pool").rglob("*.deb")]
        staging = Path(temporary) / "packages"
        staging.mkdir()
        staged_packages: list[Path] = []
        for package in existing_packages:
            staged = staging / package.name
            shutil.copy2(package, staged)
            staged_packages.append(staged)

        if remove_name:
            retained: list[Path] = []
            for package in staged_packages:
                name, version, _architecture = package_metadata(package)
                if name == remove_name and (remove_version is None or version == remove_version):
                    print(f"Removing {name} {version}")
                    package.unlink()
                else:
                    retained.append(package)
            staged_packages = retained

        if package_paths:
            for package in package_paths:
                destination = staging / package.name
                shutil.copy2(package, destination)
                staged_packages.append(destination)

        # Rebuild the repository from package artifacts. The public dists and
        # pool directories are recreated; stale objects are removed by the
        # R2 diff publisher below.
        shutil.rmtree(root / "dists", ignore_errors=True)
        shutil.rmtree(root / "pool", ignore_errors=True)
        build_repository(root, settings, key_text, passphrase, staged_packages)
        publish_diff(client, settings.bucket, root, old_keys)
        print(f"Published {settings.public_url}/dists/{settings.suite}/InRelease")


def export_key(private: bool, output: Path) -> None:
    key_text, passphrase = get_gpg_material()
    with tempfile.TemporaryDirectory(prefix="mattos-key-") as temporary:
        root = Path(temporary)
        gpg_home, fingerprint = create_gpg_home(root, key_text, passphrase)
        env = os.environ.copy()
        env["GNUPGHOME"] = str(gpg_home)
        output.parent.mkdir(parents=True, exist_ok=True)
        args = ["gpg", "--batch"]
        if private:
            args += ["--armor", "--export-secret-keys", fingerprint]
        else:
            args += ["--armor", "--export", fingerprint]
        exported = run_command(args, env=env).stdout
        output.write_text(exported, encoding="utf-8")
        output.chmod(0o600 if private else 0o644)
    print(f"Wrote {'private' if private else 'public'} key to {output}")


def public_url_check(url: str) -> str:
    request = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return f"HTTP {response.status}"
    except urllib.error.HTTPError as exc:
        return f"HTTP {exc.code}"
    except urllib.error.URLError as exc:
        return f"unreachable ({exc.reason})"


def doctor(settings: Settings) -> int:
    print("MattOS repository doctor")
    failures = 0
    for tool in ("python3", "gpg", "dpkg-deb", "bw"):
        status = "ok" if command_exists(tool) else "missing"
        print(f"  {tool}: {status}")
        failures += status == "missing"
    try:
        ensure_reprepro()
        print("  reprepro: ok")
    except RepositoryError as exc:
        print(f"  reprepro: {exc}")
        failures += 1
    try:
        ensure_boto3()
        print("  boto3: ok")
    except RepositoryError as exc:
        print(f"  boto3: {exc}")
        failures += 1
    try:
        client, resolved = r2_client(settings)
        client.head_bucket(Bucket=resolved.bucket)
        print(f"  R2 bucket {resolved.bucket}: ok")
        print(f"  public URL: {resolved.public_url}")
    except Exception as exc:  # boto3 exception classes vary by provider/version.
        print(f"  R2: failed ({exc})")
        failures += 1
    try:
        key_text, _ = get_gpg_material()
        print(f"  signing key material: {'ok' if key_text else 'missing'}")
    except RepositoryError as exc:
        print(f"  signing key material: {exc}")
        failures += 1
    return 1 if failures else 0


def list_packages(settings: Settings) -> int:
    client, settings = r2_client(settings)
    with tempfile.TemporaryDirectory(prefix="mattos-list-") as temporary:
        root = Path(temporary)
        download_remote_repository(client, settings.bucket, root)
        packages = sorted((root / "pool").rglob("*.deb"))
        if not packages:
            print("No packages are published.")
            return 0
        for package in packages:
            name, version, architecture = package_metadata(package)
            print(f"{name}\t{version}\t{architecture}")
    return 0


def verify(settings: Settings) -> int:
    client, settings = r2_client(settings)
    key_text, passphrase = get_gpg_material()
    url = f"{settings.public_url}/dists/{settings.suite}/InRelease"
    print(f"Checking {url}: {public_url_check(url)}")
    with tempfile.TemporaryDirectory(prefix="mattos-verify-") as temporary:
        root = Path(temporary)
        gpg_home, _fingerprint = create_gpg_home(root, key_text, passphrase)
        env = os.environ.copy()
        env["GNUPGHOME"] = str(gpg_home)
        release = root / "InRelease"
        try:
            client.download_file(settings.bucket, f"dists/{settings.suite}/InRelease", str(release))
        except Exception as exc:
            raise RepositoryError("Could not download InRelease from R2") from exc
        run_command(["gpg", "--batch", "--verify", str(release)], env=env)
        print("Repository signature verified.")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Manage the MattOS Debian package repository on Cloudflare R2."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("doctor", help="Check dependencies, credentials, and R2 access")
    subparsers.add_parser("init", help="Create and publish the initial empty repository")
    subparsers.add_parser("publish", help="Rebuild and publish the current repository")
    subparsers.add_parser("list", help="List packages currently published")
    subparsers.add_parser("verify", help="Verify the published InRelease signature")
    subparsers.add_parser("status", help="Show configuration and public endpoint status")

    add = subparsers.add_parser("add", help="Add .deb files and publish")
    add.add_argument("packages", nargs="+", type=Path)

    remove = subparsers.add_parser("remove", help="Remove a package and publish")
    remove.add_argument("package", help="Binary package name")
    remove.add_argument("--version", help="Remove only this exact version")

    export = subparsers.add_parser("export-key", help="Export the public signing key")
    export.add_argument("--output", type=Path, required=True)

    export_private = subparsers.add_parser(
        "export-private-key", help="Explicitly export the private signing key"
    )
    export_private.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    settings = settings_from_environment()
    try:
        if args.command == "doctor":
            return doctor(settings)
        if args.command == "init":
            ensure_reprepro()
            with_repository_workspace(settings, "init")
            return 0
        if args.command == "add":
            ensure_reprepro()
            packages = [path.expanduser().resolve() for path in args.packages]
            missing = [str(path) for path in packages if not path.is_file()]
            if missing:
                raise RepositoryError("Package file(s) not found: " + ", ".join(missing))
            with_repository_workspace(settings, "add", package_paths=packages)
            return 0
        if args.command == "remove":
            ensure_reprepro()
            with_repository_workspace(
                settings,
                "remove",
                remove_name=args.package,
                remove_version=args.version,
            )
            return 0
        if args.command == "publish":
            ensure_reprepro()
            with_repository_workspace(settings, "publish")
            return 0
        if args.command == "list":
            return list_packages(settings)
        if args.command == "verify":
            return verify(settings)
        if args.command == "status":
            client, resolved = r2_client(settings)
            print(f"R2 bucket: {resolved.bucket}")
            print(f"R2 endpoint: {resolved.endpoint}")
            print(f"Public URL: {resolved.public_url}")
            print(f"Suite/component: {resolved.suite}/{resolved.component}")
            print(f"Published objects: {len(list_remote_keys(client, resolved.bucket))}")
            print(f"InRelease: {public_url_check(resolved.public_url + '/dists/' + resolved.suite + '/InRelease')}")
            return 0
        if args.command == "export-key":
            export_key(False, args.output.expanduser().resolve())
            return 0
        if args.command == "export-private-key":
            print("Warning: exporting a private signing key creates sensitive local key material.")
            export_key(True, args.output.expanduser().resolve())
            return 0
        raise RepositoryError(f"Unknown command: {args.command}")
    except RepositoryError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

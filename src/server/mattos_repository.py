"""Persistent, locally hosted MattOS Debian repository service.

The repository is kept in versioned release directories.  A mutation builds a
new release from the currently active release and switches the ``current``
symlink only after reprepro has completed successfully.  This lets a normal
static web server expose ``<state-root>/current`` without serving a partially
written repository.
"""

from __future__ import annotations

import argparse
import fcntl
import getpass
import json
import mimetypes
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


DEFAULT_ROOT = Path("/srv/storage/Storage/MattOSPackageRepo")
DEFAULT_SUITE = "trixie"
DEFAULT_COMPONENT = "main"
DEFAULT_ARCHITECTURES = ("amd64",)
DEFAULT_BIND = "127.0.0.1"
DEFAULT_PORT = 8790
SERVICE_NAME = "mattos-repository.service"
SERVICE_PATH = Path("/etc/systemd/system") / SERVICE_NAME
CLOUDFLARED_SERVICE_NAME = "cloudflared.service"
CLOUDFLARED_SERVICE_PATH = Path("/etc/systemd/system") / CLOUDFLARED_SERVICE_NAME
CLOUDFLARE_KEY_URL = "https://pkg.cloudflare.com/cloudflare-main.gpg"
CLOUDFLARE_KEY_PATH = Path("/usr/share/keyrings/cloudflare-main.gpg")
CLOUDFLARE_SOURCE_PATH = Path("/etc/apt/sources.list.d/cloudflared.list")


class RepositoryError(RuntimeError):
    """An expected repository operation failure."""


def run_system(command: list[str], *, env: dict[str, str] | None = None) -> str:
    """Run a host-management command and return its output."""
    try:
        result = subprocess.run(command, env=env, text=True, capture_output=True, check=False)
    except FileNotFoundError as exc:
        raise RepositoryError(f"Required command is not installed: {command[0]}") from exc
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RepositoryError(f"Command failed ({result.returncode}): {command[0]}" + (f"\n{detail}" if detail else ""))
    return result.stdout


def privileged(command: list[str], *, input_text: str | None = None) -> None:
    """Run a root operation directly or through sudo."""
    prefix = [] if os.geteuid() == 0 else ["sudo"]
    if prefix and shutil.which("sudo") is None:
        raise RepositoryError("sudo is required for server setup")
    try:
        result = subprocess.run(prefix + command, input=input_text, text=True, capture_output=True, check=False)
    except FileNotFoundError as exc:
        raise RepositoryError(f"Required command is not installed: {command[0]}") from exc
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RepositoryError(f"Command failed ({result.returncode}): {command[0]}" + (f"\n{detail}" if detail else ""))


def service_user() -> str:
    """Choose the account that invoked setup, including sudo invocations."""
    return os.environ.get("MATTOS_REPOSITORY_SERVICE_USER") or os.environ.get("SUDO_USER") or getpass.getuser()


def install_dependencies() -> None:
    required = ("reprepro", "gpg", "dpkg-deb")
    missing = [name for name in required if shutil.which(name) is None]
    if not missing:
        return
    if shutil.which("apt-get") is None:
        raise RepositoryError("Missing repository dependencies and apt-get is unavailable: " + ", ".join(missing))
    packages = ["reprepro" if name == "reprepro" else "gnupg" if name == "gpg" else "dpkg-dev" for name in missing]
    privileged(["apt-get", "update"])
    privileged(["apt-get", "install", "-y", *sorted(set(packages))])


def install_cloudflared() -> None:
    """Install cloudflared from Cloudflare's signed Debian repository."""
    if shutil.which("cloudflared"):
        return
    if shutil.which("apt-get") is None:
        raise RepositoryError("cloudflared is missing and apt-get is unavailable")
    try:
        with urllib.request.urlopen(CLOUDFLARE_KEY_URL, timeout=30) as response:
            key = response.read()
    except (urllib.error.URLError, urllib.error.HTTPError) as exc:
        raise RepositoryError("Could not download Cloudflare's package signing key") from exc
    if b"BEGIN PGP PUBLIC KEY BLOCK" not in key:
        raise RepositoryError("Cloudflare package signing key response was invalid")
    with tempfile.NamedTemporaryFile("wb", prefix="cloudflare-main-", suffix=".gpg", delete=False) as key_file:
        key_file.write(key)
        key_source = Path(key_file.name)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", prefix="cloudflared-", suffix=".list", delete=False) as source_file:
        source_file.write(f"deb [signed-by={CLOUDFLARE_KEY_PATH}] https://pkg.cloudflare.com/cloudflared any main\n")
        source_source = Path(source_file.name)
    try:
        privileged(["install", "-d", "-m", "0755", str(CLOUDFLARE_KEY_PATH.parent)])
        privileged(["install", "-m", "0644", str(key_source), str(CLOUDFLARE_KEY_PATH)])
        privileged(["install", "-m", "0644", str(source_source), str(CLOUDFLARE_SOURCE_PATH)])
    finally:
        key_source.unlink(missing_ok=True)
        source_source.unlink(missing_ok=True)
    privileged(["apt-get", "update"])
    privileged(["apt-get", "install", "-y", "cloudflared"])


def cloudflared_token_path(config: "ServerConfig") -> Path:
    return config.root / "cloudflared-token"


def install_cloudflared_service(config: "ServerConfig") -> bool:
    """Install the Cloudflare connector service when a tunnel token exists."""
    token = os.environ.get("MATTOS_CLOUDFLARE_TUNNEL_TOKEN", "").strip()
    if not token and sys.stdin.isatty():
        try:
            token = getpass.getpass("Cloudflare Tunnel token (press Enter to configure later): ").strip()
        except (EOFError, KeyboardInterrupt):
            token = ""
    token_path = Path(os.environ.get("MATTOS_CLOUDFLARE_TUNNEL_TOKEN_FILE", str(cloudflared_token_path(config)))).expanduser()
    if token:
        token_path.parent.mkdir(parents=True, exist_ok=True)
        token_path.write_text(token + "\n", encoding="utf-8")
        token_path.chmod(0o600)
    if not token_path.is_file() or not token_path.read_text(encoding="utf-8").strip():
        return False
    binary = shutil.which("cloudflared") or "/usr/bin/cloudflared"
    service = "\n".join((
        "[Unit]", "Description=Cloudflare Tunnel for MattOS repository", "After=network-online.target mattos-repository.service", "Wants=network-online.target mattos-repository.service", "",
        "[Service]", "Type=notify", f"ExecStart={binary} tunnel run --token-file {token_path}", "Restart=on-failure", "RestartSec=5", "",
        "[Install]", "WantedBy=multi-user.target", "",
    ))
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", prefix="cloudflared-", suffix=".service", delete=False) as service_file:
        service_file.write(service)
        source = Path(service_file.name)
    try:
        privileged(["install", "-o", "root", "-g", "root", "-m", "0644", str(source), str(CLOUDFLARED_SERVICE_PATH)])
    finally:
        source.unlink(missing_ok=True)
    privileged(["systemctl", "daemon-reload"])
    privileged(["systemctl", "enable", "--now", CLOUDFLARED_SERVICE_NAME])
    return True


def ensure_tree_permissions(root: Path, user: str) -> None:
    """Keep repository contents service-readable without touching package data."""
    try:
        import pwd
        uid = pwd.getpwnam(user).pw_uid
        gid = pwd.getpwnam(user).pw_gid
    except KeyError as exc:
        raise RepositoryError(f"Repository service user does not exist: {user}") from exc
    for path in sorted(root.rglob("*")):
        try:
            os.chown(path, uid, gid)
            os.chmod(path, 0o755 if path.is_dir() else (0o600 if path.name in {"private-key.asc", "token"} else 0o644))
        except PermissionError as exc:
            raise RepositoryError(f"Could not set repository permissions on {path}") from exc
    os.chown(root, uid, gid)
    os.chmod(root, 0o755)


def service_definition(config: "ServerConfig", user: str) -> str:
    script = Path(__file__).resolve().parents[2] / "Tools" / "ManageMattOSRepositoryServer.py"
    return "\n".join((
        "[Unit]", "Description=MattOS local Debian repository API", "After=network-online.target", "Wants=network-online.target", "",
        "[Service]", "Type=simple", f"User={user}", f"WorkingDirectory={script.parent.parent}",
        f"Environment=MATTOS_REPOSITORY_ROOT={config.root}", f"Environment=MATTOS_REPOSITORY_TOKEN_FILE={config.token_file}",
        f"Environment=MATTOS_REPOSITORY_PUBLIC_URL={config.public_url}",
        f"ExecStart=/usr/bin/python3 {script} serve --bind {os.environ.get('MATTOS_REPOSITORY_BIND', DEFAULT_BIND)} --port {os.environ.get('MATTOS_REPOSITORY_PORT', str(DEFAULT_PORT))}",
        "Restart=on-failure", "RestartSec=5", "", "[Install]", "WantedBy=multi-user.target", "",
    ))


def install_service(config: "ServerConfig", user: str) -> None:
    """Install and enable the generated service, updating only its own unit."""
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", prefix="mattos-repository-", suffix=".service", delete=False) as temporary:
        temporary.write(service_definition(config, user))
        source = Path(temporary.name)
    try:
        privileged(["install", "-o", "root", "-g", "root", "-m", "0644", str(source), str(SERVICE_PATH)])
    finally:
        source.unlink(missing_ok=True)
    if shutil.which("systemctl") is None:
        raise RepositoryError("systemctl is required to install the MattOS repository service")
    privileged(["systemctl", "daemon-reload"])
    privileged(["systemctl", "enable", "--now", SERVICE_NAME])


def run(command: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None) -> str:
    try:
        result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True, check=False)
    except FileNotFoundError as exc:
        raise RepositoryError(f"Required command is not installed: {command[0]}") from exc
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RepositoryError(f"Command failed ({result.returncode}): {command[0]}" + (f"\n{detail}" if detail else ""))
    return result.stdout


def validate_architectures(value: str) -> tuple[str, ...]:
    result = tuple(dict.fromkeys(item.strip() for item in value.split(",") if item.strip()))
    if not result or "all" in result or any(not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", item) for item in result):
        raise RepositoryError("Invalid repository architecture configuration")
    return result


@dataclass(frozen=True)
class ServerConfig:
    root: Path = DEFAULT_ROOT
    suite: str = DEFAULT_SUITE
    component: str = DEFAULT_COMPONENT
    architectures: tuple[str, ...] = DEFAULT_ARCHITECTURES
    public_url: str = "http://127.0.0.1:8790/repository"
    token_file: Path = DEFAULT_ROOT / "api-token"
    private_key_file: Path | None = None

    @classmethod
    def from_env(cls) -> "ServerConfig":
        root = Path(os.environ.get("MATTOS_REPOSITORY_ROOT", str(DEFAULT_ROOT))).expanduser()
        key = os.environ.get("MATTOS_REPOSITORY_PRIVATE_KEY_FILE")
        return cls(
            root=root,
            suite=os.environ.get("MATTOS_REPOSITORY_SUITE", DEFAULT_SUITE),
            component=os.environ.get("MATTOS_REPOSITORY_COMPONENT", DEFAULT_COMPONENT),
            architectures=validate_architectures(os.environ.get("MATTOS_REPOSITORY_ARCHITECTURES", "amd64")),
            public_url=os.environ.get("MATTOS_REPOSITORY_PUBLIC_URL", "http://127.0.0.1:8790/repository").rstrip("/"),
            token_file=Path(os.environ.get("MATTOS_REPOSITORY_TOKEN_FILE", str(root / "api-token"))).expanduser(),
            private_key_file=Path(key).expanduser() if key else None,
        )


def package_metadata(path: Path) -> tuple[str, str, str]:
    output = run(["dpkg-deb", "--show", "--showformat=${Package}\n${Version}\n${Architecture}\n", "--", str(path)])
    values = output.splitlines()
    if len(values) != 3 or not all(values):
        raise RepositoryError(f"Malformed Debian package metadata: {path.name}")
    return tuple(item.strip() for item in values)  # type: ignore[return-value]


class RepositoryManager:
    """Manage the persistent reprepro repository on the home server."""

    def __init__(self, config: ServerConfig) -> None:
        self.config = config
        self.root = config.root
        self.releases = self.root / "releases"
        self.current = self.root / "current"
        self.lock_path = self.root / ".lock"

    def ensure_layout(self) -> None:
        self.releases.mkdir(parents=True, exist_ok=True)
        self.root.mkdir(parents=True, exist_ok=True)

    def _lock(self):
        self.ensure_layout()
        handle = self.lock_path.open("a+")
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        return handle

    def _active(self) -> Path | None:
        if self.current.is_symlink():
            target = self.current.resolve()
            if target.is_dir():
                return target
        return self.current if self.current.is_dir() else None

    def _write_config(self, root: Path, fingerprint: str) -> None:
        conf = root / "conf"
        conf.mkdir(parents=True, exist_ok=True)
        (conf / "distributions").write_text(
            "".join((
                "Origin: MattOS\n", "Label: MattOS\n", f"Codename: {self.config.suite}\n",
                f"Suite: {self.config.suite}\n", f"Architectures: {' '.join(self.config.architectures)}\n",
                f"Components: {self.config.component}\n", "Description: MattOS Debian packages\n",
                f"SignWith: {fingerprint}\n", "DebIndices: Packages Release . .gz\n",
            )), encoding="utf-8",
        )

    def _key_material(self) -> str:
        path = self.config.private_key_file or (self.root / "private-key.asc")
        if not path.is_file():
            raise RepositoryError(f"Signing key is missing: {path}; run the server init command")
        return path.read_text(encoding="utf-8")

    def ensure_token(self) -> str:
        """Create the API credential once and return it for provisioning clients."""
        path = self.config.token_file
        if path.is_file() and path.read_text(encoding="utf-8").strip():
            return path.read_text(encoding="utf-8").strip()
        path.parent.mkdir(parents=True, exist_ok=True)
        token = secrets.token_urlsafe(32)
        path.write_text(token + "\n", encoding="utf-8")
        path.chmod(0o600)
        return token

    def _prepare_gpg(self, stage: Path) -> tuple[Path, str]:
        home = stage / ".gnupg"
        home.mkdir(mode=0o700)
        env = os.environ.copy()
        env["GNUPGHOME"] = str(home)
        # Feed the armored key through stdin without putting it in argv.
        key = self._key_material()
        result = subprocess.run(["gpg", "--batch", "--import"], cwd=stage, env=env, input=key, text=True, capture_output=True, check=False)
        if result.returncode:
            raise RepositoryError(f"Could not import repository signing key: {(result.stderr or result.stdout).strip()}")
        listing = run(["gpg", "--batch", "--with-colons", "--list-secret-keys"], cwd=stage, env=env)
        for line in listing.splitlines():
            parts = line.split(":")
            if len(parts) > 9 and parts[0] == "fpr":
                return home, parts[9]
        raise RepositoryError("The signing key contains no secret key")

    def _stage_from_active(self, stage: Path) -> None:
        active = self._active()
        if active:
            def copy_file(source: str, destination: str) -> str:
                # Package payloads are immutable and can be hard-linked. Copy
                # indexes and reprepro's database because reprepro may rewrite
                # them during export; hard-linking those would break atomicity.
                if "pool" in Path(source).parts and Path(source).suffix == ".deb":
                    return os.link(source, destination) or destination
                return shutil.copy2(source, destination)

            shutil.copytree(active, stage, copy_function=copy_file, dirs_exist_ok=True)
        else:
            stage.mkdir(parents=True)

    def _commit(self, stage: Path) -> None:
        release = self.releases / f"release-{time.time_ns()}-{secrets.token_hex(4)}"
        os.replace(stage, release)
        pointer = self.root / ".current.new"
        pointer.unlink(missing_ok=True)
        pointer.symlink_to(release)
        os.replace(pointer, self.current)
        releases = sorted((item for item in self.releases.iterdir() if item.is_dir()), key=lambda item: item.name)
        for old in releases[:-2]:
            shutil.rmtree(old, ignore_errors=True)

    def _build(self, stage: Path, packages: list[Path]) -> None:
        gpg_home, fingerprint = self._prepare_gpg(stage)
        self._write_config(stage, fingerprint)
        env = os.environ.copy()
        env["GNUPGHOME"] = str(gpg_home)
        for package in packages:
            run(["reprepro", "--basedir", str(stage), "--section", "misc", "includedeb", self.config.suite, str(package)], env=env)
        run(["reprepro", "--basedir", str(stage), "export"], env=env)
        shutil.rmtree(gpg_home, ignore_errors=True)

    def init(self) -> None:
        with self._lock() as handle:
            try:
                token = self.ensure_token()
                if self._active():
                    return
                self.ensure_layout()
                key_path = self.config.private_key_file or (self.root / "private-key.asc")
                if not key_path.is_file():
                    key_path.parent.mkdir(parents=True, exist_ok=True)
                    with tempfile.TemporaryDirectory(prefix="mattos-gpg-") as temp:
                        home = Path(temp) / "gnupg"
                        home.mkdir(mode=0o700)
                        env = os.environ.copy(); env["GNUPGHOME"] = str(home)
                        identity = os.environ.get("MATTOS_GPG_IDENTITY", "MattOS Repository Signing Key <packages@mattsherfey.com>")
                        run(["gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", "", "--quick-gen-key", identity, os.environ.get("MATTOS_GPG_ALGORITHM", "rsa4096"), "sign", os.environ.get("MATTOS_GPG_EXPIRY", "3y")], env=env)
                        key_path.write_text(run(["gpg", "--batch", "--armor", "--export-secret-keys"], env=env), encoding="utf-8")
                    key_path.chmod(0o600)
                stage = Path(tempfile.mkdtemp(prefix="mattos-repository-", dir=self.releases))
                try:
                    self._build(stage, [])
                    self._commit(stage)
                except Exception:
                    shutil.rmtree(stage, ignore_errors=True)
                    raise
            finally:
                handle.close()

    def reconcile_configuration(self) -> None:
        """Regenerate metadata only when repository configuration changed."""
        active = self._active()
        if not active:
            return
        distributions = active / "conf" / "distributions"
        current = distributions.read_text(encoding="utf-8") if distributions.is_file() else ""
        expected = (
            f"Suite: {self.config.suite}\n",
            f"Components: {self.config.component}\n",
            f"Architectures: {' '.join(self.config.architectures)}\n",
        )
        if all(line in current for line in expected):
            return
        with self._lock() as handle:
            stage = Path(tempfile.mkdtemp(prefix="mattos-repository-", dir=self.releases))
            try:
                self._stage_from_active(stage)
                self._build(stage, sorted(active.rglob("*.deb")))
                self._commit(stage)
            except Exception:
                shutil.rmtree(stage, ignore_errors=True)
                raise
            finally:
                handle.close()

    def add(self, package: Path) -> dict[str, str]:
        package = package.resolve()
        if not package.is_file() or package.suffix != ".deb":
            raise RepositoryError("Upload must be a regular .deb file")
        name, version, architecture = package_metadata(package)
        if architecture != "all" and architecture not in self.config.architectures:
            raise RepositoryError(f"Package architecture {architecture} is not configured")
        with self._lock() as handle:
            stage = Path(tempfile.mkdtemp(prefix="mattos-repository-", dir=self.releases))
            try:
                self._stage_from_active(stage)
                incoming = stage / ".incoming.deb"
                shutil.copy2(package, incoming)
                self._build(stage, [incoming])
                incoming.unlink(missing_ok=True)
                self._commit(stage)
            except Exception:
                shutil.rmtree(stage, ignore_errors=True)
                raise
            finally:
                handle.close()
        return {"name": name, "version": version, "architecture": architecture}

    def remove(self, name: str, version: str | None = None) -> None:
        with self._lock() as handle:
            active = self._active()
            if not active:
                raise RepositoryError("Repository is not initialized")
            packages = []
            for path in sorted(active.rglob("*.deb")):
                metadata = package_metadata(path)
                if metadata[0] == name and (version is None or metadata[1] == version):
                    continue
                packages.append(path)
            if version and not any(package_metadata(path)[0] == name and package_metadata(path)[1] == version for path in active.rglob("*.deb")):
                raise RepositoryError(f"Package/version not found: {name} {version}")
            stage = Path(tempfile.mkdtemp(prefix="mattos-repository-", dir=self.releases))
            try:
                self._build(stage, packages)
                self._commit(stage)
            except Exception:
                shutil.rmtree(stage, ignore_errors=True)
                raise
            finally:
                handle.close()

    def packages(self) -> list[dict[str, str]]:
        active = self._active()
        if not active:
            return []
        result = []
        for path in sorted(active.rglob("*.deb")):
            name, version, architecture = package_metadata(path)
            result.append({"name": name, "version": version, "architecture": architecture})
        return result

    def status(self) -> dict[str, Any]:
        active = self._active()
        return {"initialized": active is not None, "root": str(self.root), "public_url": self.config.public_url, "suite": self.config.suite, "component": self.config.component, "architectures": list(self.config.architectures), "packages": len(self.packages())}

    def public_key(self) -> str:
        with tempfile.TemporaryDirectory(prefix="mattos-public-key-") as temp:
            stage = Path(temp)
            home, fingerprint = self._prepare_gpg(stage)
            env = os.environ.copy(); env["GNUPGHOME"] = str(home)
            return run(["gpg", "--batch", "--armor", "--export", fingerprint], env=env, cwd=stage)

    def private_key(self) -> str:
        """Return the key only for the explicitly requested authenticated export."""
        return self._key_material()

    def verify(self) -> None:
        active = self._active()
        if not active:
            raise RepositoryError("Repository is not initialized")
        run(["reprepro", "--basedir", str(active), "check", self.config.suite])


def setup_server(config: ServerConfig) -> tuple[str, bool]:
    """Install dependencies and reconcile the server installation safely."""
    install_dependencies()
    install_cloudflared()
    user = service_user()
    root = config.root
    privileged(["install", "-d", "-o", user, "-g", user, "-m", "0755", str(root)])
    privileged(["install", "-d", "-o", user, "-g", user, "-m", "0755", str(config.token_file.parent)])
    if os.geteuid() != 0 and root.exists():
        privileged(["chown", "-R", user, str(root)])
    manager = RepositoryManager(config)
    manager.init()
    manager.reconcile_configuration()
    ensure_tree_permissions(root, user)
    install_service(config, user)
    tunnel_configured = install_cloudflared_service(config)
    return manager.ensure_token(), tunnel_configured


class RepositoryHandler(BaseHTTPRequestHandler):
    server_version = "MattOSRepository/1.0"

    @property
    def manager(self) -> RepositoryManager:
        return self.server.manager  # type: ignore[attr-defined]

    def _authorized(self) -> bool:
        expected = self.server.token  # type: ignore[attr-defined]
        if not expected:
            return True
        supplied = self.headers.get("Authorization", "")
        return secrets.compare_digest(supplied.removeprefix("Bearer ").strip(), expected)

    def _send(self, status: int, payload: Any, content_type: str = "application/json", cache_control: str | None = None) -> None:
        data = payload if isinstance(payload, bytes) else (json.dumps(payload).encode() if content_type == "application/json" else str(payload).encode())
        self.send_response(status); self.send_header("Content-Type", content_type); self.send_header("Content-Length", str(len(data)))
        if cache_control:
            self.send_header("Cache-Control", cache_control)
        self.end_headers(); self.wfile.write(data)

    def _error(self, status: int, message: str) -> None:
        self._send(status, {"error": message})

    def _serve_repository_file(self, path: str) -> bool:
        """Serve only public dists/pool files from the active release."""
        prefix = "/repository/"
        if path == "/repository":
            self.send_response(301)
            self.send_header("Location", "/repository/")
            self.end_headers()
            return True
        if not path.startswith(prefix):
            return False
        relative = path.removeprefix(prefix)
        if not relative.startswith(("dists/", "pool/")):
            self._error(404, "repository file not found")
            return True
        active = self.manager._active()
        if not active:
            self._error(404, "repository is not initialized")
            return True
        root = active.resolve()
        target = (root / relative).resolve()
        try:
            target.relative_to(root)
        except ValueError:
            self._error(404, "repository file not found")
            return True
        if not target.is_file():
            self._error(404, "repository file not found")
            return True
        data = target.read_bytes()
        content_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        cache_control = "public, max-age=31536000, immutable" if "/pool/" in path and target.suffix == ".deb" else "no-cache, max-age=0, must-revalidate"
        self._send(200, data, content_type, cache_control)
        return True

    def do_GET(self) -> None:
        if self._serve_repository_file(urlparse(self.path).path):
            return
        if not self._authorized(): return self._error(401, "authentication required")
        path = urlparse(self.path).path
        try:
            if path == "/v1/status": return self._send(200, self.manager.status())
            if path == "/v1/packages": return self._send(200, {"packages": self.manager.packages()})
            if path == "/v1/public-key": return self._send(200, self.manager.public_key(), "text/plain; charset=utf-8")
            if path == "/v1/private-key": return self._send(200, self.manager.private_key(), "text/plain; charset=utf-8")
            if path == "/v1/verify": self.manager.verify(); return self._send(200, {"verified": True})
            self._error(404, "unknown endpoint")
        except RepositoryError as exc: self._error(400, str(exc))

    def do_POST(self) -> None:
        if not self._authorized(): return self._error(401, "authentication required")
        path = urlparse(self.path).path
        try:
            if path == "/v1/upload":
                length = int(self.headers.get("Content-Length", "0")); filename = self.headers.get("X-Package-Filename", "package.deb")
                if Path(filename).name != filename or not filename.endswith(".deb") or length <= 0: return self._error(400, "invalid package upload")
                with tempfile.NamedTemporaryFile(prefix="mattos-upload-", suffix=".deb", delete=False) as temp:
                    remaining = length
                    while remaining:
                        block = self.rfile.read(min(1024 * 1024, remaining));
                        if not block: raise RepositoryError("incomplete package upload")
                        temp.write(block); remaining -= len(block)
                    temporary = Path(temp.name)
                try: return self._send(200, self.manager.add(temporary))
                finally: temporary.unlink(missing_ok=True)
            if path == "/v1/remove":
                length = int(self.headers.get("Content-Length", "0")); body = json.loads(self.rfile.read(length))
                self.manager.remove(str(body["name"]), str(body["version"]) if body.get("version") else None); return self._send(200, {"removed": True})
            if path == "/v1/init": self.manager.init(); return self._send(200, self.manager.status())
            if path == "/v1/publish": self.manager.verify(); return self._send(200, {"published": True})
            self._error(404, "unknown endpoint")
        except (RepositoryError, KeyError, ValueError, json.JSONDecodeError) as exc: self._error(400, str(exc))

    def log_message(self, format: str, *args: Any) -> None:
        print(f"[mattos-repository] {format % args}", file=sys.stderr)


def serve(config: ServerConfig, bind: str, port: int) -> None:
    manager = RepositoryManager(config)
    token = config.token_file.read_text(encoding="utf-8").strip() if config.token_file.is_file() else ""
    server = ThreadingHTTPServer((bind, port), RepositoryHandler)
    server.manager = manager  # type: ignore[attr-defined]
    server.token = token  # type: ignore[attr-defined]
    print(f"MattOS repository API listening on {bind}:{port}")
    server.serve_forever()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Manage the local MattOS Debian repository")
    parser.add_argument("--root", type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init"); sub.add_parser("setup"); sub.add_parser("status"); sub.add_parser("verify"); sub.add_parser("list")
    add = sub.add_parser("add"); add.add_argument("package", type=Path)
    remove = sub.add_parser("remove"); remove.add_argument("name"); remove.add_argument("--version")
    api = sub.add_parser("serve"); api.add_argument("--bind", default=os.environ.get("MATTOS_REPOSITORY_BIND", DEFAULT_BIND)); api.add_argument("--port", type=int, default=int(os.environ.get("MATTOS_REPOSITORY_PORT", str(DEFAULT_PORT))))
    sub.add_parser("token")
    args = parser.parse_args(argv)
    config = ServerConfig.from_env()
    if args.root: config = ServerConfig(args.root.expanduser(), config.suite, config.component, config.architectures, config.public_url, config.token_file, config.private_key_file)
    manager = RepositoryManager(config)
    try:
        if args.command == "serve":
            if not config.token_file.is_file() and os.environ.get("MATTOS_REPOSITORY_ALLOW_ANONYMOUS") != "1":
                raise RepositoryError("API token is missing; run init first or explicitly allow anonymous access")
            serve(config, args.bind, args.port)
        elif args.command == "token": print(manager.ensure_token())
        elif args.command == "init": manager.init(); print(json.dumps(manager.status(), indent=2, sort_keys=True))
        elif args.command == "setup":
            token, tunnel_configured = setup_server(config)
            print(json.dumps(manager.status(), indent=2, sort_keys=True))
            print("API token (store it in the client token file):")
            print(token)
            if tunnel_configured:
                print("Cloudflare Tunnel service: configured and running")
            else:
                print("Cloudflare Tunnel: cloudflared installed; tunnel token still needs to be supplied")
        elif args.command == "status": print(json.dumps(manager.status(), indent=2, sort_keys=True))
        elif args.command == "verify": manager.verify(); print("Repository verification passed.")
        elif args.command == "list":
            for item in manager.packages(): print(f"{item['name']}\t{item['version']}\t{item['architecture']}")
        elif args.command == "add": print(json.dumps(manager.add(args.package), sort_keys=True))
        elif args.command == "remove": manager.remove(args.name, args.version); print("Package removed.")
        return 0
    except RepositoryError as exc:
        print(f"Error: {exc}", file=sys.stderr); return 1


if __name__ == "__main__":
    raise SystemExit(main())

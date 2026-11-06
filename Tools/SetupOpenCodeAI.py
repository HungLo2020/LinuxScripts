#!/usr/bin/env python3
"""Connect OpenCode v2 on this computer to Ollama on hunglosvr."""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener

BASE_URL = "http://hunglosvr:11434/v1"


def configure(path: Path) -> None:
    """Merge the server address into an existing JSON configuration."""
    jsonc = path.with_suffix(".jsonc")
    if jsonc.exists():
        raise ValueError(f"{jsonc} exists; edit its providers.ollama.settings.baseURL manually to avoid conflicting configs")
    if path.exists():
        config = json.loads(path.read_text(encoding="utf-8"))
    else:
        config = {}
    if not isinstance(config, dict):
        raise ValueError("OpenCode configuration must be a JSON object")
    providers = config.setdefault("providers", {})
    if not isinstance(providers, dict):
        raise ValueError("The providers setting must be a JSON object")
    ollama = providers.setdefault("ollama", {})
    if not isinstance(ollama, dict):
        raise ValueError("The ollama provider setting must be a JSON object")
    settings = ollama.setdefault("settings", {})
    if not isinstance(settings, dict):
        raise ValueError("The ollama provider settings must be a JSON object")
    settings["baseURL"] = BASE_URL
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(config, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
        temporary.chmod(mode)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    config_dir = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    path = config_dir / "opencode" / "opencode.json"
    try:
        configure(path)
    except (OSError, ValueError) as error:
        print(f"Could not configure OpenCode: {error}", file=sys.stderr)
        return 1
    print(f"Configured {path} for {BASE_URL}")
    try:
        # Bypass HTTP proxy settings for this private server.
        with build_opener(ProxyHandler({})).open("http://hunglosvr:11434/api/tags", timeout=5) as response:
            data = json.load(response)
        print(f"Server reachable; Ollama reports {len(data['models'])} models.")
    except (OSError, URLError, ValueError, KeyError, TypeError) as error:
        print(f"Could not check the server: {error}. Check Tailscale and DNS, then retry.", file=sys.stderr)
    print("Reload or restart OpenCode, then select an Ollama model with /models.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

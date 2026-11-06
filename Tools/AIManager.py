#!/usr/bin/env python3
"""Manage the Ollama models on hunglosvr over SSH."""

from __future__ import annotations

import argparse
import shlex
import subprocess
import sys

HOST = "hunglosvr"
REMOTE_REPOSITORY = "/home/matt/Documents/Repos/LinuxScripts"


def run_remote(command: str) -> int:
    """Run a command on the server, forwarding output and exit status."""
    try:
        return subprocess.run(
            ["ssh", "-o", "ConnectTimeout=10", HOST, command], check=False
        ).returncode
    except OSError as error:
        print(f"Could not run SSH: {error}", file=sys.stderr)
        return 1


def model_command(action: str, name: str | None = None) -> int:
    arguments = ["docker", "exec", "ollama", "ollama", action]
    if name is not None:
        arguments.extend(["--", name])
    return run_remote(shlex.join(arguments))


def update_ollama() -> int:
    # Pull first so a network failure leaves the existing container running.
    # Reuse the server's launcher for its GPU, network and persistent volume setup.
    launcher = (
        "import sys; sys.path.insert(0, 'src'); "
        "from containers.workloads import WORKLOADS, main_for_workload; "
        "WORKLOADS['ollama'].ollama_image = 'ollama/ollama:latest'; "
        "sys.argv = ['run_ollama.py']; "
        "raise SystemExit(main_for_workload('ollama'))"
    )
    command = (
        f"cd {shlex.quote(REMOTE_REPOSITORY)} && "
        "docker pull ollama/ollama:latest && "
        "docker stop ollama && docker rm ollama && "
        f"python3 -c {shlex.quote(launcher)}"
    )
    return run_remote(command)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--list", action="store_true", help="list installed Ollama models")
    actions.add_argument("--install", metavar="MODEL", help="download an Ollama model")
    actions.add_argument("--delete", metavar="MODEL", help="delete an Ollama model")
    actions.add_argument("--update", action="store_true", help="update the Ollama container")
    args = parser.parse_args()
    if args.list:
        return model_command("list")
    if args.install is not None:
        return model_command("pull", args.install)
    if args.delete is not None:
        return model_command("rm", args.delete)
    return update_ollama()


if __name__ == "__main__":
    raise SystemExit(main())

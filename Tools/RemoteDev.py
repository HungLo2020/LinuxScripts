#!/usr/bin/env python3
"""Open a persistent tmux development session in a repository on the server.

The script lists the repositories on the server, prompts for one (Enter accepts
the default), and opens a new terminal window attached to a tmux session named
after it, starting in that repository's directory. The launching terminal is
released immediately. Dropped SSH connections are retried automatically and
land back in the same tmux session; detaching or exiting tmux closes the window.
Closing the window only disconnects; the tmux session keeps running on the server.
"""

from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from argparse import SUPPRESS, ArgumentParser, Namespace
from collections.abc import Callable, Sequence
from pathlib import Path


DEFAULT_HOST = "hunglosvr"
DEFAULT_REPOSITORY = "MattOS"
REMOTE_REPOSITORIES_DIRECTORY = "/home/matt/Documents/Repos"
# Detect dead connections within about 15 seconds instead of hanging.
SSH_OPTIONS = ("-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3", "-o", "ConnectTimeout=10")
SSH_CONNECTION_FAILURE = 255
MISSING_TMUX = 3
INITIAL_RETRY_DELAY = 2.0
MAXIMUM_RETRY_DELAY = 30.0
# A session that stays up this long resets the retry backoff.
STABLE_SESSION_SECONDS = 60.0
# Terminal emulators in preference order, with the arguments that precede the command to run.
TERMINAL_LAUNCHERS = (
    ("konsole", ("-e",)),
    ("x-terminal-emulator", ("-e",)),
    ("gnome-terminal", ("--",)),
    ("kitty", ()),
    ("alacritty", ("-e",)),
    ("wezterm", ("start", "--")),
    ("xterm", ("-e",)),
)


def parse_arguments(argv: Sequence[str] | None = None) -> Namespace:
    """Return command-line options."""

    parser = ArgumentParser(description="Attach to a persistent tmux session in a repository on the server.")
    parser.add_argument("repository", nargs="?", help="repository to open, skipping the selection menu")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"SSH host to connect to (default: {DEFAULT_HOST})")
    parser.add_argument("--here", action="store_true", help="run in the current terminal instead of opening a new window")
    # Set by the spawned window so errors stay readable before it closes.
    parser.add_argument("--pause-on-error", action="store_true", help=SUPPRESS)
    return parser.parse_args(argv)


def list_repositories(host: str) -> list[str]:
    """Return the repository directory names on the server, verifying tmux is installed."""

    script = (
        f"command -v tmux >/dev/null 2>&1 || exit {MISSING_TMUX}; "
        f"find {shlex.quote(REMOTE_REPOSITORIES_DIRECTORY)} -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\\n'"
    )
    result = subprocess.run(("ssh", *SSH_OPTIONS, host, script), capture_output=True, text=True, check=False)
    if result.returncode == MISSING_TMUX:
        raise RuntimeError(f"tmux is not installed on {host}.")
    if result.returncode != 0:
        detail = result.stderr.strip() or f"ssh exited with status {result.returncode}"
        raise RuntimeError(f"Could not list repositories on {host}: {detail}")
    return sorted((name for name in result.stdout.splitlines() if name), key=str.lower)


def resolve_repository(answer: str, repositories: Sequence[str], default: str) -> str | None:
    """Return the repository chosen by a menu answer, or None when it matches nothing."""

    answer = answer.strip()
    if not answer:
        return default
    if answer.isdigit():
        index = int(answer)
        return repositories[index - 1] if 1 <= index <= len(repositories) else None
    matches = [name for name in repositories if name.lower() == answer.lower()]
    return matches[0] if matches else None


def choose_repository(
    repositories: Sequence[str],
    host: str,
    prompt: Callable[[str], str] = input,
) -> str | None:
    """Prompt for a repository and return it, or None when input ends."""

    default = DEFAULT_REPOSITORY if DEFAULT_REPOSITORY in repositories else repositories[0]
    print(f"Repositories on {host}:")
    for index, name in enumerate(repositories, start=1):
        print(f"  {index}) {name}{'  (default)' if name == default else ''}")
    while True:
        try:
            answer = prompt(f"Select [{default}]: ")
        except EOFError:
            return None
        selected = resolve_repository(answer, repositories, default)
        if selected is not None:
            return selected
        print("Enter a listed number or repository name, or press Enter for the default.")


def session_name(repository: str) -> str:
    """Return a tmux-safe session name; tmux rejects '.' and ':' in names."""

    return re.sub(r"[.:]", "_", repository)


def remote_command(repository: str) -> str:
    """Return the server command that creates or attaches to the repository's tmux session."""

    directory = f"{REMOTE_REPOSITORIES_DIRECTORY}/{repository}"
    return shlex.join(("tmux", "new-session", "-A", "-s", session_name(repository), "-c", directory))


def connect(
    host: str,
    repository: str,
    run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    """Attach to the repository's tmux session, reconnecting whenever SSH drops."""

    command = ("ssh", "-t", *SSH_OPTIONS, host, remote_command(repository))
    delay = INITIAL_RETRY_DELAY
    try:
        while True:
            started = clock()
            returncode = run(command, check=False).returncode
            if returncode != SSH_CONNECTION_FAILURE:
                return returncode
            if clock() - started >= STABLE_SESSION_SECONDS:
                delay = INITIAL_RETRY_DELAY
            print(f"\nConnection to {host} lost; reconnecting in {delay:g}s (Ctrl-C to stop)...", file=sys.stderr)
            sleep(delay)
            delay = min(delay * 2, MAXIMUM_RETRY_DELAY)
    except KeyboardInterrupt:
        print(file=sys.stderr)
        return 130


def terminal_command(command: Sequence[str], which: Callable[[str], str | None] = shutil.which) -> list[str] | None:
    """Return a command that runs `command` in a new terminal window, or None without a graphical terminal."""

    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return None
    for name, prefix in TERMINAL_LAUNCHERS:
        executable = which(name)
        if executable:
            return [executable, *prefix, *command]
    return None


def open_window(host: str, repository: str, popen: Callable[..., object] = subprocess.Popen) -> bool:
    """Open a detached terminal window running the session; return False when no terminal is available."""

    session = (sys.executable, str(Path(__file__).resolve()), "--here", "--pause-on-error", "--host", host, repository)
    command = terminal_command(session)
    if command is None:
        return False
    # A new session keeps the window alive when the launching terminal closes.
    popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return True


def pause(prompt: Callable[[str], str] = input) -> None:
    """Wait for Enter so a closing window's last message can be read."""

    try:
        prompt("Press Enter to close this window.")
    except (EOFError, KeyboardInterrupt):
        pass


def select_repository(arguments: Namespace) -> str | None:
    """Return the requested or interactively chosen repository, or None when the menu is abandoned."""

    repositories = list_repositories(arguments.host)
    if not repositories:
        raise RuntimeError(f"No repositories found in {REMOTE_REPOSITORIES_DIRECTORY} on {arguments.host}.")
    if not arguments.repository:
        return choose_repository(repositories, arguments.host)
    repository = resolve_repository(arguments.repository, repositories, DEFAULT_REPOSITORY)
    if repository is None:
        raise RuntimeError(f"Repository {arguments.repository!r} was not found on {arguments.host}.")
    return repository


def attach(host: str, repository: str, pause_on_error: bool = False) -> int:
    """Connect in the current terminal, optionally holding the window open after a failure."""

    if os.environ.get("TMUX"):
        print("Note: running inside local tmux; press the prefix twice (Ctrl-b Ctrl-b) to reach the remote session.")
    returncode = connect(host, repository)
    if pause_on_error and returncode not in {0, 130}:
        print(f"Session ended with status {returncode}.", file=sys.stderr)
        pause()
    return returncode


def main(argv: Sequence[str] | None = None) -> int:
    """Select a server repository and attach to its persistent tmux session."""

    arguments = parse_arguments(argv)
    if arguments.pause_on_error and arguments.repository:
        # The launcher already validated the repository; reconnect straight away.
        return attach(arguments.host, arguments.repository, pause_on_error=True)
    try:
        repository = select_repository(arguments)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(file=sys.stderr)
        return 130
    if repository is None:
        return 0

    if not arguments.here:
        try:
            if open_window(arguments.host, repository):
                print(f"Opened {repository} on {arguments.host} in a new terminal window.")
                return 0
        except OSError as error:
            print(f"Could not open a new terminal window ({error}); connecting in this terminal.", file=sys.stderr)
        else:
            print("No graphical terminal found; connecting in this terminal.", file=sys.stderr)

    return attach(arguments.host, repository)


if __name__ == "__main__":
    raise SystemExit(main())

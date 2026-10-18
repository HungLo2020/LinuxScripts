"""Regression coverage for the remote tmux development launcher."""

from __future__ import annotations

import importlib.util
import io
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load_tool(name: str):
    """Load a Tool module without running its script entry point."""

    path = ROOT / "Tools" / name
    specification = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(specification)
    assert specification.loader is not None
    specification.loader.exec_module(module)
    return module


remote_dev = load_tool("RemoteDev.py")
REPOSITORIES = ["LinuxScripts", "MattOS", "MattPackages"]


def completed(returncode: int, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=(), returncode=returncode, stdout=stdout, stderr=stderr)


class RepositorySelectionTests(unittest.TestCase):
    def test_enter_accepts_mattos_default(self):
        with redirect_stdout(io.StringIO()) as output:
            selected = remote_dev.choose_repository(REPOSITORIES, "hunglosvr", prompt=lambda _: "")
        self.assertEqual(selected, "MattOS")
        self.assertIn("2) MattOS  (default)", output.getvalue())

    def test_number_and_case_insensitive_name_select_repositories(self):
        self.assertEqual(remote_dev.resolve_repository("1", REPOSITORIES, "MattOS"), "LinuxScripts")
        self.assertEqual(remote_dev.resolve_repository("mattpackages", REPOSITORIES, "MattOS"), "MattPackages")
        self.assertIsNone(remote_dev.resolve_repository("4", REPOSITORIES, "MattOS"))
        self.assertIsNone(remote_dev.resolve_repository("0", REPOSITORIES, "MattOS"))
        self.assertIsNone(remote_dev.resolve_repository("Missing", REPOSITORIES, "MattOS"))

    def test_invalid_answer_reprompts(self):
        answers = iter(["nope", "3"])
        with redirect_stdout(io.StringIO()):
            selected = remote_dev.choose_repository(REPOSITORIES, "hunglosvr", prompt=lambda _: next(answers))
        self.assertEqual(selected, "MattPackages")

    def test_first_repository_is_default_without_mattos(self):
        with redirect_stdout(io.StringIO()):
            selected = remote_dev.choose_repository(["Alpha", "Beta"], "hunglosvr", prompt=lambda _: "")
        self.assertEqual(selected, "Alpha")


class RemoteCommandTests(unittest.TestCase):
    def test_remote_command_attaches_or_creates_session_in_repository(self):
        self.assertEqual(
            remote_dev.remote_command("MattOS"),
            "tmux new-session -A -s MattOS -c /home/matt/Documents/Repos/MattOS",
        )

    def test_session_name_replaces_characters_tmux_rejects(self):
        self.assertEqual(remote_dev.session_name("site.v2:old"), "site_v2_old")

    def test_list_repositories_sorts_names_and_reports_missing_tmux(self):
        with patch.object(remote_dev.subprocess, "run", return_value=completed(0, "MattOS\nalpha\nLinuxScripts\n")):
            self.assertEqual(remote_dev.list_repositories("hunglosvr"), ["alpha", "LinuxScripts", "MattOS"])
        with patch.object(remote_dev.subprocess, "run", return_value=completed(remote_dev.MISSING_TMUX)):
            with self.assertRaisesRegex(RuntimeError, "tmux is not installed"):
                remote_dev.list_repositories("hunglosvr")


class ReconnectTests(unittest.TestCase):
    def test_connection_failures_retry_until_clean_exit(self):
        results = iter([completed(255), completed(255), completed(0)])
        commands = []
        delays = []

        def run(command, check):
            commands.append(command)
            return next(results)

        with redirect_stderr(io.StringIO()):
            returncode = remote_dev.connect("hunglosvr", "MattOS", run=run, sleep=delays.append, clock=lambda: 0.0)
        self.assertEqual(returncode, 0)
        self.assertEqual(len(commands), 3)
        self.assertEqual(commands[0][:2], ("ssh", "-t"))
        self.assertEqual(commands[0][-2:], ("hunglosvr", remote_dev.remote_command("MattOS")))
        self.assertEqual(delays, [2.0, 4.0])

    def test_non_connection_failure_is_returned_without_retry(self):
        with redirect_stderr(io.StringIO()):
            returncode = remote_dev.connect("hunglosvr", "MattOS", run=lambda *_, **__: completed(1), sleep=self.fail)
        self.assertEqual(returncode, 1)

    def test_backoff_caps_and_resets_after_stable_session(self):
        results = iter([completed(255)] * 6 + [completed(0)])
        times = iter([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 100, 0, 0])
        delays = []
        with redirect_stderr(io.StringIO()):
            remote_dev.connect(
                "hunglosvr",
                "MattOS",
                run=lambda *_, **__: next(results),
                sleep=delays.append,
                clock=lambda: next(times),
            )
        self.assertEqual(delays, [2.0, 4.0, 8.0, 16.0, 30.0, 2.0])

    def test_ctrl_c_stops_reconnecting(self):
        def interrupt(_delay):
            raise KeyboardInterrupt

        with redirect_stderr(io.StringIO()):
            returncode = remote_dev.connect("hunglosvr", "MattOS", run=lambda *_, **__: completed(255), sleep=interrupt)
        self.assertEqual(returncode, 130)


class NewWindowTests(unittest.TestCase):
    def test_konsole_is_preferred_in_graphical_session(self):
        found = {"konsole": "/usr/bin/konsole", "xterm": "/usr/bin/xterm"}
        with patch.dict(remote_dev.os.environ, {"WAYLAND_DISPLAY": "wayland-0"}, clear=True):
            command = remote_dev.terminal_command(["run", "it"], which=found.get)
        self.assertEqual(command, ["/usr/bin/konsole", "-e", "run", "it"])

    def test_no_terminal_without_display_or_emulator(self):
        with patch.dict(remote_dev.os.environ, {}, clear=True):
            self.assertIsNone(remote_dev.terminal_command(["run"], which=lambda _: "/usr/bin/konsole"))
        with patch.dict(remote_dev.os.environ, {"DISPLAY": ":0"}, clear=True):
            self.assertIsNone(remote_dev.terminal_command(["run"], which=lambda _: None))

    def test_window_runs_detached_session_in_place(self):
        calls = []
        with patch.object(remote_dev, "terminal_command", side_effect=lambda command: ["/usr/bin/konsole", "-e", *command]):
            opened = remote_dev.open_window("hunglosvr", "MattOS", popen=lambda command, **options: calls.append((command, options)))
        self.assertTrue(opened)
        command, options = calls[0]
        self.assertEqual(command[:2], ["/usr/bin/konsole", "-e"])
        self.assertEqual(command[-5:], ["--here", "--pause-on-error", "--host", "hunglosvr", "MattOS"])
        self.assertTrue(options["start_new_session"])
        self.assertIs(options["stdin"], subprocess.DEVNULL)

    def test_launcher_returns_after_opening_window(self):
        with patch.object(remote_dev, "list_repositories", return_value=REPOSITORIES), patch.object(
            remote_dev, "open_window", return_value=True
        ) as open_window, patch.object(remote_dev, "connect") as connect, redirect_stdout(io.StringIO()):
            self.assertEqual(remote_dev.main(["MattOS"]), 0)
        open_window.assert_called_once_with("hunglosvr", "MattOS")
        connect.assert_not_called()

    def test_falls_back_to_current_terminal_without_window(self):
        with patch.object(remote_dev, "list_repositories", return_value=REPOSITORIES), patch.object(
            remote_dev, "open_window", return_value=False
        ), patch.object(remote_dev, "connect", return_value=0) as connect, redirect_stderr(io.StringIO()):
            self.assertEqual(remote_dev.main(["MattOS"]), 0)
        connect.assert_called_once_with("hunglosvr", "MattOS")

    def test_spawned_window_skips_listing_and_pauses_on_error(self):
        with patch.object(remote_dev, "list_repositories") as list_repositories, patch.object(
            remote_dev, "connect", return_value=1
        ), patch.object(remote_dev, "pause") as pause, redirect_stderr(io.StringIO()):
            self.assertEqual(remote_dev.main(["--here", "--pause-on-error", "MattOS"]), 1)
        list_repositories.assert_not_called()
        pause.assert_called_once()


if __name__ == "__main__":
    unittest.main()

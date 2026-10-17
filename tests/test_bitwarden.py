"""Regression coverage for shared Bitwarden authentication behavior."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from bitwarden import BitwardenClient, BitwardenError


class BitwardenClientTests(unittest.TestCase):
    def test_flatpak_cli_preserves_unlock_environment_and_session(self):
        responses = iter((
            subprocess.CompletedProcess((), 0, "installed", ""),
            subprocess.CompletedProcess((), 0, json.dumps({"status": "locked"}), ""),
            subprocess.CompletedProcess((), 0, "session-token\n", ""),
            subprocess.CompletedProcess((), 0, "secret\n", ""),
        ))
        inherited_sessions = []

        def run(*args, **kwargs):
            inherited_sessions.append(os.environ.get("BW_SESSION"))
            return next(responses)

        with patch("bitwarden.shutil.which", side_effect=lambda name: "/usr/bin/flatpak" if name == "flatpak" else None), patch(
            "bitwarden.subprocess.run", side_effect=run
        ) as run_command, patch("bitwarden.getpass.getpass", return_value="master-password"), patch.dict("os.environ", {}, clear=True):
            self.assertEqual(BitwardenClient().password("PCPassword"), "secret")
        calls = run_command.call_args_list
        self.assertEqual(calls[0].args[0], ("flatpak", "info", "com.bitwarden.desktop"))
        prefix = ("flatpak", "run", "--command=bw", "com.bitwarden.desktop")
        self.assertEqual(calls[1].args[0], (*prefix, "status", "--raw"))
        self.assertEqual(calls[2].args[0], (*prefix, "unlock", "--passwordenv", "BW_MASTER_PASSWORD", "--nointeraction", "--raw"))
        self.assertEqual(calls[2].kwargs["env"]["BW_MASTER_PASSWORD"], "master-password")
        self.assertEqual(calls[3].args[0], (*prefix, "get", "password", "PCPassword"))
        self.assertIsNone(calls[3].kwargs["env"])
        self.assertEqual(inherited_sessions[-1], "session-token")

    def test_flatpak_cli_preserves_json_stdin_and_interactive_prompts(self):
        with patch("bitwarden.shutil.which", side_effect=lambda name: "/usr/bin/flatpak" if name == "flatpak" else None), patch(
            "bitwarden.subprocess.run", return_value=subprocess.CompletedProcess((), 0, "", "")
        ) as run_command:
            client = BitwardenClient()
            client.run(("bw", "encode"), input_text='{"name":"example"}')
            self.assertEqual(run_command.call_args.kwargs["input"], '{"name":"example"}')
            client.run(("bw", "login"), capture_output=False)
            self.assertEqual(run_command.call_args.args[0], ("flatpak", "run", "--command=bw", "com.bitwarden.desktop", "login"))
            self.assertFalse(run_command.call_args.kwargs["capture_output"])

    def test_flatpak_runtime_without_bitwarden_fails_clearly(self):
        with patch("bitwarden.shutil.which", side_effect=lambda name: "/usr/bin/flatpak" if name == "flatpak" else None), patch(
            "bitwarden.subprocess.run", return_value=subprocess.CompletedProcess((), 1, "", "not installed")
        ) as run_command:
            with self.assertRaisesRegex(BitwardenError, "Install bw or the com.bitwarden.desktop Flatpak"):
                BitwardenClient().ensure_session()
        self.assertEqual(run_command.call_count, 1)

    def test_missing_cli_and_flatpak_fail_without_executing_commands(self):
        with patch("bitwarden.shutil.which", return_value=None), patch("bitwarden.subprocess.run") as run_command:
            with self.assertRaises(BitwardenError):
                BitwardenClient().ensure_session()
        run_command.assert_not_called()

    def test_locked_vault_uses_visible_getpass_then_noninteractive_unlock(self):
        responses = iter(
            (
                subprocess.CompletedProcess(("bw", "status", "--raw"), 0, json.dumps({"status": "locked"}), ""),
                subprocess.CompletedProcess(("bw", "unlock"), 0, "session-token\n", ""),
                subprocess.CompletedProcess(("bw", "get", "password", "PCPassword"), 0, "secret\n", ""),
            )
        )
        with patch("bitwarden.shutil.which", return_value="/usr/bin/bw"), patch("bitwarden.subprocess.run", side_effect=lambda *args, **kwargs: next(responses)) as run_command, patch(
            "bitwarden.getpass.getpass", return_value="master-password"
        ) as prompt:
            self.assertEqual(BitwardenClient().password("PCPassword"), "secret")
        prompt.assert_called_once_with("Bitwarden master password: ")
        commands = [call.args[0] for call in run_command.call_args_list]
        self.assertIn(("bw", "unlock", "--passwordenv", "BW_MASTER_PASSWORD", "--nointeraction", "--raw"), commands)
        self.assertNotIn(("bw", "unlock", "--raw"), commands)

    def test_noninteractive_locked_vault_fails_without_prompting(self):
        status = subprocess.CompletedProcess(("bw", "status", "--raw"), 0, json.dumps({"status": "locked"}), "")
        with patch("bitwarden.shutil.which", return_value="/usr/bin/bw"), patch("bitwarden.subprocess.run", return_value=status), patch(
            "bitwarden.getpass.getpass"
        ) as prompt:
            with self.assertRaisesRegex(BitwardenError, "interactive authentication is disabled"):
                BitwardenClient(non_interactive=True).ensure_session()
        prompt.assert_not_called()


if __name__ == "__main__":
    unittest.main()

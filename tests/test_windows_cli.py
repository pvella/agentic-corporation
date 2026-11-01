"""Cross-platform CLI helper tests (env prep, argv resolve, terminate path).

    python3 -m unittest tests.test_windows_cli -v
"""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

import agent_harness as h  # noqa: E402


class CliHelperTests(unittest.TestCase):
    def test_prepare_cli_env_sets_home_and_user(self) -> None:
        with mock.patch.dict(os.environ, {"HOME": "/tmp/office-home", "PATH": "/usr/bin"}, clear=True):
            env = h._prepare_cli_env()
        self.assertEqual(env["HOME"], "/tmp/office-home")
        self.assertIn("USER", env)
        self.assertIn(str(Path("/tmp/office-home") / ".local" / "bin"), env["PATH"].split(os.pathsep))
        self.assertEqual(env.get("FORCE_COLOR"), "0")

    def test_resolve_cli_argv_passthrough_when_missing(self) -> None:
        tokens = ["definitely-not-a-real-binary-xyz", "-p"]
        self.assertEqual(h._resolve_cli_argv(tokens), tokens)

    def test_is_claude_recognises_cmd_wrapper(self) -> None:
        self.assertTrue(h.CliRunner._is_claude(["claude", "-p"]))
        self.assertTrue(h.CliRunner._is_claude(["claude.exe", "-p"]))
        self.assertTrue(h.CliRunner._is_claude(["claude.cmd", "-p"]))
        self.assertTrue(h.CliRunner._is_claude(["cmd.exe", "/c", "C:\\npm\\claude.cmd", "-p"]))
        self.assertFalse(h.CliRunner._is_claude(["pytest", "-q"]))

    def test_is_windows_helper(self) -> None:
        self.assertEqual(h._is_windows(), os.name == "nt")


    def test_split_cli_cmd_keeps_windows_paths(self) -> None:
        cmd = r"C:\Users\pvell\.local\bin\claude.exe -p --output-format text {prompt}"
        with mock.patch.object(h, "_is_windows", return_value=True):
            tokens = h._split_cli_cmd(cmd)
        self.assertEqual(tokens[0], r"C:\Users\pvell\.local\bin\claude.exe")
        self.assertIn("{prompt}", tokens)

    def test_split_cli_cmd_posix_still_handles_quotes(self) -> None:
        cmd = "claude -p --append-system-prompt 'hello world' {prompt}"
        with mock.patch.object(h, "_is_windows", return_value=False):
            tokens = h._split_cli_cmd(cmd)
        self.assertEqual(tokens[0], "claude")
        self.assertIn("hello world", tokens)

if __name__ == "__main__":
    unittest.main()

"""Windows vault tests: Credential Manager chunking, no plaintext fallback, Hello unlock dispatch.

Runs anywhere (no real keyring / PowerShell needed):
    python3 -m unittest tests.test_windows_vault -v
"""
from __future__ import annotations

import hashlib
import re
import subprocess
import sys
import tempfile
import types
import unittest
import uuid
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))

import office_vault as ov  # noqa: E402
import vault_auth  # noqa: E402

CRED_BLOB_MAX = 2560  # Windows CRED_MAX_CREDENTIAL_BLOB_SIZE (bytes)


class FakeKeyring:
    """In-memory stand-in for the keyring module that enforces the WinVault blob limit."""

    def __init__(self) -> None:
        self.data: dict[tuple[str, str], str] = {}

    def set_password(self, service: str, user: str, value: str) -> None:
        if len(value.encode("utf-16-le")) > CRED_BLOB_MAX:
            raise OSError("(1783, 'CredWrite', 'The stub received bad data.')")
        self.data[(service, user)] = value

    def get_password(self, service: str, user: str) -> str | None:
        return self.data.get((service, user))

    def delete_password(self, service: str, user: str) -> None:
        if (service, user) not in self.data:
            raise KeyError(user)
        del self.data[(service, user)]


class TestKeyringChunking(unittest.TestCase):
    def setUp(self) -> None:
        self.kr = FakeKeyring()
        self.store = ov.KeyringStore(self.kr)

    def test_short_value_stored_as_is(self) -> None:
        self.store.set("TOKEN", "abc123")
        self.assertEqual(self.kr.data, {(ov.KEYRING_SERVICE, "TOKEN"): "abc123"})
        self.assertEqual(self.store.get("TOKEN"), "abc123")

    def test_long_value_roundtrips_within_blob_limit(self) -> None:
        # Mix of ASCII, BMP and astral chars (surrogate pairs in UTF-16).
        value = ("-----BEGIN KEY-----\n" + "x" * 3000 + "é" * 500 + "\U0001F511" * 700)
        self.store.set("PEM", value)
        self.assertEqual(self.store.get("PEM"), value)
        self.assertGreater(len(self.kr.data), 2)
        for v in self.kr.data.values():
            self.assertLessEqual(len(v.encode("utf-16-le")), CRED_BLOB_MAX)

    def test_overwrite_long_with_short_removes_parts(self) -> None:
        self.store.set("K", "y" * 2000)
        self.store.set("K", "short")
        self.assertEqual(self.kr.data, {(ov.KEYRING_SERVICE, "K"): "short"})

    def test_delete_removes_parts(self) -> None:
        self.store.set("K", "z" * 2000)
        self.store.delete("K")
        self.assertEqual(self.kr.data, {})
        self.assertIsNone(self.store.get("K"))

    def test_value_that_looks_like_header_roundtrips(self) -> None:
        tricky = ov._CHUNK_MARKER + "1/" + "0" * 64
        self.store.set("T", tricky)
        self.assertEqual(self.store.get("T"), tricky)

    def test_tampered_part_fails_checksum(self) -> None:
        self.store.set("K", "q" * 1500)
        self.kr.data[(ov.KEYRING_SERVICE, "K.part1")] = "tampered"
        self.assertIsNone(self.store.get("K"))

    def test_missing_part_returns_none(self) -> None:
        self.store.set("K", "q" * 1500)
        del self.kr.data[(ov.KEYRING_SERVICE, "K.part0")]
        self.assertIsNone(self.store.get("K"))

    def test_vault_end_to_end_with_long_secret(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            vault = ov.OfficeVault(meta_path=Path(tmp) / ".office_vault.json", store=self.store)
            big = "s" * 5000
            vault.add_secret("SVC_JSON", big, agents=["coder"])
            self.assertEqual(vault.env_for_agent("coder")["SVC_JSON"], big)
            self.assertNotIn("[REDACTED]", vault.scrub("nothing secret"))
            self.assertEqual(vault.scrub(f"leak {big}"), "leak [REDACTED]")


class TestDefaultStore(unittest.TestCase):
    def test_windows_without_keyring_refuses_plaintext(self) -> None:
        with mock.patch.object(ov.platform, "system", return_value="Windows"), \
             mock.patch.object(ov, "_usable_keyring", return_value=None):
            store = ov.default_store()
        self.assertIsInstance(store, ov.UnavailableStore)
        self.assertNotIsInstance(store, ov.FileStore)
        with self.assertRaisesRegex(RuntimeError, "keyring"):
            store.set("X", "v")
        with tempfile.TemporaryDirectory() as tmp:
            vault = ov.OfficeVault(meta_path=Path(tmp) / "v.json", store=store)
            with self.assertRaisesRegex(RuntimeError, "keyring"):
                vault.add_secret("X", "value")

    def test_windows_with_keyring_uses_credential_manager(self) -> None:
        kr = FakeKeyring()
        with mock.patch.object(ov.platform, "system", return_value="Windows"), \
             mock.patch.object(ov, "_usable_keyring", return_value=kr):
            store = ov.default_store()
        self.assertIsInstance(store, ov.KeyringStore)
        self.assertIs(store.kr, kr)

    def test_linux_without_keyring_keeps_file_store(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, \
             mock.patch.object(ov.platform, "system", return_value="Linux"), \
             mock.patch.object(ov, "_usable_keyring", return_value=None), \
             mock.patch.object(ov.Path, "home", return_value=Path(tmp)):
            self.assertIsInstance(ov.default_store(), ov.FileStore)

    def test_fail_backend_is_not_usable(self) -> None:
        fail_cls = type("Keyring", (), {"priority": 0})
        fail_cls.__module__ = "keyring.backends.fail"
        fake = types.ModuleType("keyring")
        fake.get_keyring = lambda: fail_cls()  # type: ignore[attr-defined]
        with mock.patch.dict(sys.modules, {"keyring": fake}):
            self.assertIsNone(ov._usable_keyring())

    def test_real_backend_is_usable(self) -> None:
        win_cls = type("WinVaultKeyring", (), {"priority": 5})
        win_cls.__module__ = "keyring.backends.Windows"
        fake = types.ModuleType("keyring")
        fake.get_keyring = lambda: win_cls()  # type: ignore[attr-defined]
        with mock.patch.dict(sys.modules, {"keyring": fake}):
            self.assertIs(ov._usable_keyring(), fake)


class TestWindowsUnlock(unittest.TestCase):
    def _run(self, returncode: int, stdout: str = "", stderr: str = ""):
        return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr=stderr)

    def test_windows_never_uses_keyring_touch(self) -> None:
        with mock.patch.object(vault_auth.platform, "system", return_value="Windows"), \
             mock.patch.object(vault_auth, "_powershell", return_value=r"C:\ps.exe"), \
             mock.patch.object(vault_auth.subprocess, "run", return_value=self._run(1, stderr="cancelled")), \
             mock.patch.object(vault_auth, "_keyring_touch") as touch:
            ok, msg = vault_auth.authenticate("why")
        self.assertFalse(ok)
        self.assertEqual(msg, "cancelled")
        touch.assert_not_called()

    def test_windows_success_and_invocation(self) -> None:
        with mock.patch.object(vault_auth.platform, "system", return_value="Windows"), \
             mock.patch.object(vault_auth, "_powershell", return_value=r"C:\ps.exe"), \
             mock.patch.object(vault_auth.subprocess, "run",
                               return_value=self._run(0, stdout="ok (Windows Hello)\n")) as run:
            ok, msg = vault_auth.authenticate("Unlock it; $(evil) `x`")
        self.assertTrue(ok)
        self.assertEqual(msg, "ok (Windows Hello)")
        argv = run.call_args.args[0]
        self.assertEqual(argv[0], r"C:\ps.exe")
        self.assertEqual(argv[-2:], ["-File", str(vault_auth.WIN_HELPER)])
        # Reason travels in the environment, never on the command line.
        self.assertNotIn("evil", " ".join(argv))
        env = run.call_args.kwargs["env"]
        self.assertEqual(env["AGENTIC_VAULT_REASON"], "Unlock it; $(evil) `x`")
        self.assertNotIn("AGENTIC_VAULT_METHOD", env)

    def test_exit_codes_map_to_messages(self) -> None:
        cases = {
            2: "Windows sign-in check unavailable: boom",
            3: "vault unlock helper error: boom",
            1: "boom",
        }
        for code, expected in cases.items():
            with mock.patch.object(vault_auth, "_powershell", return_value="ps"), \
                 mock.patch.object(vault_auth.subprocess, "run", return_value=self._run(code, stderr="noise\nboom\n")):
                self.assertEqual(vault_auth._windows_auth("r"), (False, expected))

    def test_missing_powershell_fails_closed(self) -> None:
        with mock.patch.object(vault_auth, "_powershell", return_value=None):
            ok, msg = vault_auth._windows_auth("r")
        self.assertFalse(ok)
        self.assertIn("PowerShell", msg)

    def test_timeout_fails_closed(self) -> None:
        with mock.patch.object(vault_auth, "_powershell", return_value="ps"), \
             mock.patch.object(vault_auth.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired(cmd="ps", timeout=1)):
            self.assertEqual(vault_auth._windows_auth("r"), (False, "authentication timed out"))

    def test_password_method_passed_via_env(self) -> None:
        with mock.patch.object(vault_auth, "_powershell", return_value="ps"), \
             mock.patch.object(vault_auth.subprocess, "run", return_value=self._run(0, stdout="ok")) as run:
            vault_auth._windows_auth("r", method="password")
        self.assertEqual(run.call_args.kwargs["env"]["AGENTIC_VAULT_METHOD"], "password")


class TestUnlockScript(unittest.TestCase):
    SCRIPT = ROOT / "tools" / "vault_unlock_windows.ps1"

    def test_script_is_ascii(self) -> None:
        # PowerShell 5.1 reads BOM-less scripts as ANSI; keep it plain ASCII.
        self.SCRIPT.read_bytes().decode("ascii")

    def test_async_operation_iid_matches_winrt_hash(self) -> None:
        ns = uuid.UUID("11f47ad5-7b73-42c0-abae-878b1e16adee")

        def piid(sig: str) -> str:
            h = bytearray(hashlib.sha1(ns.bytes + sig.encode()).digest()[:16])
            h[6] = (h[6] & 0x0F) | 0x50
            h[8] = (h[8] & 0x3F) | 0x80
            return str(uuid.UUID(bytes=bytes(h))).upper()

        async_op = "{9fc2b0bb-e446-44e2-aa61-9cab8f636af2}"
        # Known published IID: IAsyncOperation<bool>.
        self.assertEqual(piid(f"pinterface({async_op};b1)"), "CDB5EFB3-5788-509D-9BE1-71CCB8A3362A")
        expected = piid(f"pinterface({async_op};enum(Windows.Security.Credentials.UI.UserConsentVerificationResult;i4))")
        text = self.SCRIPT.read_text(encoding="ascii")
        m = re.search(r'Guid\("([0-9A-F-]+)"\),\s*\n\s*InterfaceType[^\n]*\n\s*interface IAsyncOperationVerificationResult', text)
        self.assertIsNotNone(m)
        self.assertEqual(m.group(1), expected)


if __name__ == "__main__":
    unittest.main()

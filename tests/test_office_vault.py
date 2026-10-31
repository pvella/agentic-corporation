"""Vault scrub + metadata isolation tests (no Keychain required)."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from office_vault import FileStore, OfficeVault, format_vault_system_addon, validate_name


class TestOfficeVault(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store = FileStore(self.root / "secrets")
        self.vault = OfficeVault(meta_path=self.root / ".office_vault.json", store=self.store)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_validate_name(self) -> None:
        self.assertEqual(validate_name("GITHUB_TOKEN"), "GITHUB_TOKEN")
        with self.assertRaises(ValueError):
            validate_name("bad name")
        with self.assertRaises(ValueError):
            validate_name("1abc")

    def test_meta_never_contains_value(self) -> None:
        secret = "super-secret-value-xyz-999"
        self.vault.add_secret("API_KEY", secret, description="test key", agents=["coder"])
        raw = (self.root / ".office_vault.json").read_text(encoding="utf-8")
        self.assertNotIn(secret, raw)
        data = json.loads(raw)
        for item in data["secrets"]:
            self.assertNotIn("value", item)
            self.assertNotIn("secret", item)
            self.assertEqual(item["name"], "API_KEY")

    def test_scrub_redacts_from_output(self) -> None:
        secret = "hunter2-vault-test-abc"
        self.vault.add_secret("PWD", secret, agents="all")
        text = f"Command failed with password {secret} in logs"
        scrubbed = self.vault.scrub(text)
        self.assertNotIn(secret, scrubbed)
        self.assertIn("[REDACTED]", scrubbed)

    def test_env_injection_respects_acl(self) -> None:
        secret = "only-for-coder-zzz"
        self.vault.add_secret("TOK", secret, agents=["coder"])
        env_coder = self.vault.env_for_agent("coder")
        env_qa = self.vault.env_for_agent("qa")
        self.assertEqual(env_coder.get("TOK"), secret)
        self.assertNotIn("TOK", env_qa)

    def test_grant_revoke(self) -> None:
        self.vault.add_secret("X", "val-xxxx-yyyy", agents=[])
        self.vault.grant("X", "qa")
        self.assertTrue(self.vault.agent_may_use("X", "qa"))
        self.vault.revoke("X", "qa")
        self.assertFalse(self.vault.agent_may_use("X", "qa"))

    def test_system_addon_has_no_value(self) -> None:
        secret = "never-in-prompt-12345"
        self.vault.add_secret("S", secret, description="a secret", agents=["chief_of_staff"])
        addon = format_vault_system_addon(self.vault, "chief_of_staff", is_cos=True)
        self.assertNotIn(secret, addon)
        self.assertIn("$S", addon)
        self.assertIn("vault_list", addon)

    def test_request_flow_and_decline(self) -> None:
        req = self.vault.add_request("coder", "NEW_TOK", label="New token", description="for CI")
        self.assertEqual(len(self.vault.pending), 1)
        result = self.vault.submit_request(req["request_id"], "brand-new-secret-val")
        self.assertEqual(result["meta"]["name"], "NEW_TOK")
        self.assertTrue(self.vault.agent_may_use("NEW_TOK", "coder"))
        raw = (self.root / ".office_vault.json").read_text()
        self.assertNotIn("brand-new-secret-val", raw)

        req2 = self.vault.add_request("qa", "OTHER", label="Other")
        dismissed = self.vault.dismiss_request(req2["request_id"])
        self.assertIsNotNone(dismissed)
        with self.assertRaises(PermissionError):
            self.vault.add_request("qa", "OTHER", label="Other again")


if __name__ == "__main__":
    unittest.main()

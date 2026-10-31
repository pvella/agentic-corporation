#!/usr/bin/env python3
"""Authenticate the human operator for vault unlock.

macOS: LocalAuthentication via tools/vault_unlock (Touch ID or login password).
Linux/Windows: touch a sentinel in the platform keyring / file store (prompts unlock).
"""
from __future__ import annotations

import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "tools" / "vault_unlock"
SRC = ROOT / "tools" / "vault_unlock.swift"
REASON_DEFAULT = "Unlock the Agentic Corporation office vault"


def _ensure_macos_helper() -> str | None:
    if HELPER.is_file():
        return None
    if not SRC.is_file():
        return "tools/vault_unlock.swift missing"
    try:
        subprocess.run(
            ["swiftc", "-O", "-o", str(HELPER), str(SRC),
             "-framework", "LocalAuthentication"],
            check=True, capture_output=True, text=True, timeout=180,
        )
    except Exception as exc:
        return f"could not build vault_unlock: {exc}"
    if not HELPER.is_file():
        return "vault_unlock binary missing after build"
    return None


def _macos_local_auth(reason: str) -> tuple[bool, str]:
    err = _ensure_macos_helper()
    if err:
        return False, err
    try:
        proc = subprocess.run(
            [str(HELPER), reason],
            capture_output=True, text=True, timeout=130,
        )
    except subprocess.TimeoutExpired:
        return False, "authentication timed out"
    except OSError as exc:
        return False, str(exc)
    if proc.returncode == 0:
        return True, "ok"
    detail = (proc.stderr or "").strip() or "authentication failed or cancelled"
    if proc.returncode == 2:
        return False, f"LocalAuthentication unavailable: {detail}"
    return False, detail


def _keyring_touch() -> tuple[bool, str]:
    name = "__VAULT_UNLOCK_SENTINEL__"
    try:
        if platform.system() == "Darwin":
            subprocess.run(
                ["security", "add-generic-password",
                 "-s", f"agentic-corp.{name}", "-a", "agentic-corp",
                 "-w", "ok", "-U"],
                check=False, capture_output=True, text=True,
            )
            return True, "keychain touch ok"
        try:
            import keyring  # type: ignore
            existing = keyring.get_password("agentic-corp", name)
            if not existing:
                keyring.set_password("agentic-corp", name, "ok")
            return True, "keyring ok"
        except Exception:
            base = Path.home() / ".local" / "share" / "agentic-corp" / "secrets"
            base.mkdir(parents=True, exist_ok=True)
            p = base / name
            if not p.is_file():
                p.write_text("ok", encoding="utf-8")
            return True, "file-store ok"
    except Exception as exc:
        return False, f"keyring unlock failed: {exc}"


def authenticate(reason: str = REASON_DEFAULT) -> tuple[bool, str]:
    if platform.system() == "Darwin":
        ok, msg = _macos_local_auth(reason)
        if ok:
            return True, msg
        if "unavailable" in msg.lower():
            return _keyring_touch()
        return False, msg
    return _keyring_touch()


if __name__ == "__main__":
    ok, msg = authenticate(" ".join(sys.argv[1:]) or REASON_DEFAULT)
    print(msg)
    sys.exit(0 if ok else 1)

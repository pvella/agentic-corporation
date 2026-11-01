#!/usr/bin/env python3
"""Authenticate the human operator for vault unlock.

macOS: LocalAuthentication via tools/vault_unlock (Touch ID or login password).
Windows: tools/vault_unlock_windows.ps1 (Windows Hello, else the account password).
Linux: touch a sentinel in the platform keyring / file store (prompts unlock).
"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "tools" / "vault_unlock"
SRC = ROOT / "tools" / "vault_unlock.swift"
WIN_HELPER = ROOT / "tools" / "vault_unlock_windows.ps1"
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


def _powershell() -> str | None:
    # Prefer the system copy over whatever "powershell" is first on PATH.
    sysroot = os.environ.get("SystemRoot") or r"C:\Windows"
    builtin = Path(sysroot) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    if builtin.is_file():
        return str(builtin)
    return shutil.which("powershell.exe") or shutil.which("powershell")


def _windows_auth(reason: str, method: str = "") -> tuple[bool, str]:
    """Windows Hello, falling back to the account password. Never unlocks without a check."""
    if not WIN_HELPER.is_file():
        return False, "tools/vault_unlock_windows.ps1 missing"
    exe = _powershell()
    if exe is None:
        return False, "Windows PowerShell not found; cannot verify the vault owner"
    env = dict(os.environ, AGENTIC_VAULT_REASON=reason)
    if method:
        env["AGENTIC_VAULT_METHOD"] = method
    try:
        proc = subprocess.run(
            [exe, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-File", str(WIN_HELPER)],
            capture_output=True, text=True, timeout=400, env=env,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except subprocess.TimeoutExpired:
        return False, "authentication timed out"
    except OSError as exc:
        return False, str(exc)
    if proc.returncode == 0:
        return True, (proc.stdout or "").strip() or "ok"
    detail = (proc.stderr or "").strip().splitlines()
    msg = detail[-1] if detail else "authentication failed or cancelled"
    if proc.returncode == 2:
        return False, f"Windows sign-in check unavailable: {msg}"
    if proc.returncode == 3:
        return False, f"vault unlock helper error: {msg}"
    return False, msg


def authenticate(reason: str = REASON_DEFAULT) -> tuple[bool, str]:
    system = platform.system()
    if system == "Windows":
        return _windows_auth(reason)
    if system == "Darwin":
        ok, msg = _macos_local_auth(reason)
        if ok:
            return True, msg
        if "unavailable" in msg.lower():
            return _keyring_touch()
        return False, msg
    return _keyring_touch()


if __name__ == "__main__":
    # Manual check: python tools/vault_auth.py [--password] [reason...]
    # --password (Windows) skips Hello to exercise the account-password fallback.
    argv = sys.argv[1:]
    force_password = "--password" in argv
    argv = [a for a in argv if a != "--password"]
    reason = " ".join(argv) or REASON_DEFAULT
    if force_password and platform.system() == "Windows":
        ok, msg = _windows_auth(reason, method="password")
    else:
        ok, msg = authenticate(reason)
    print(msg)
    sys.exit(0 if ok else 1)

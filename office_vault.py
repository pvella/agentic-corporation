"""Office Vault — secret metadata + Keychain (macOS) / file (Linux) values.

Values NEVER go in vault.json, logs, UI, git or prompts. Metadata only:
  name, description, agents (list or "all"), created_at, last_used_at.
Service name in Keychain: agentic-corp.<NAME>
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import platform
import re
import secrets
import subprocess
import time
from pathlib import Path
from typing import Any

log = logging.getLogger("office_vault")

SERVICE_PREFIX = "agentic-corp."
KEYCHAIN_ACCOUNT = "agentic-corp"
DEFAULT_META_NAME = ".office_vault.json"
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
HMAC_KEY_NAME = "__VAULT_HMAC_KEY__"
UNLOCK_TTL_SEC = 120.0

# CoS agent_id (and display-name match helpers live in the harness).
COS_AGENT_ID = "chief_of_staff"


def _now() -> float:
    return time.time()


def validate_name(name: str) -> str:
    n = str(name or "").strip()
    if not NAME_RE.match(n):
        raise ValueError(
            "secret name must be 1–64 chars: letters, digits, underscore; "
            "start with a letter or underscore (becomes the env var name)"
        )
    return n


class SecretStore:
    """Platform secret value backend. Never logs values."""

    def set(self, name: str, value: str) -> None:
        raise NotImplementedError

    def get(self, name: str) -> str | None:
        raise NotImplementedError

    def delete(self, name: str) -> None:
        raise NotImplementedError


class KeychainStore(SecretStore):
    def _service(self, name: str) -> str:
        return f"{SERVICE_PREFIX}{name}"

    def set(self, name: str, value: str) -> None:
        # -U updates if present. Never echo value.
        subprocess.run(
            [
                "security", "add-generic-password",
                "-s", self._service(name),
                "-a", KEYCHAIN_ACCOUNT,
                "-w", value,
                "-U",
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    def get(self, name: str) -> str | None:
        try:
            proc = subprocess.run(
                [
                    "security", "find-generic-password",
                    "-s", self._service(name),
                    "-a", KEYCHAIN_ACCOUNT,
                    "-w",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
        except FileNotFoundError:
            return None
        if proc.returncode != 0:
            return None
        # security -w prints the password with a trailing newline
        return proc.stdout.rstrip("\n")

    def delete(self, name: str) -> None:
        subprocess.run(
            [
                "security", "delete-generic-password",
                "-s", self._service(name),
                "-a", KEYCHAIN_ACCOUNT,
            ],
            check=False,
            capture_output=True,
            text=True,
        )


class FileStore(SecretStore):
    """0600 files under ~/.local/share/agentic-corp/secrets/ (outside the repo)."""

    def __init__(self, root: Path | None = None) -> None:
        base = root or (Path.home() / ".local" / "share" / "agentic-corp" / "secrets")
        self.root = base
        self.root.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(self.root, 0o700)
        except OSError:
            pass

    def _path(self, name: str) -> Path:
        return self.root / name

    def set(self, name: str, value: str) -> None:
        p = self._path(name)
        p.write_text(value, encoding="utf-8")
        os.chmod(p, 0o600)

    def get(self, name: str) -> str | None:
        p = self._path(name)
        if not p.is_file():
            return None
        return p.read_text(encoding="utf-8")

    def delete(self, name: str) -> None:
        p = self._path(name)
        try:
            p.unlink(missing_ok=True)
        except OSError:
            pass


def default_store() -> SecretStore:
    if platform.system() == "Darwin":
        return KeychainStore()
    # Prefer keyring if installed
    try:
        import keyring  # type: ignore

        class KeyringStore(SecretStore):
            def set(self, name: str, value: str) -> None:
                keyring.set_password(SERVICE_PREFIX.rstrip("."), name, value)

            def get(self, name: str) -> str | None:
                return keyring.get_password(SERVICE_PREFIX.rstrip("."), name)

            def delete(self, name: str) -> None:
                try:
                    keyring.delete_password(SERVICE_PREFIX.rstrip("."), name)
                except Exception:
                    pass

        return KeyringStore()
    except Exception:
        return FileStore()


class OfficeVault:
    def __init__(self, meta_path: str | Path | None = None, store: SecretStore | None = None) -> None:
        self.meta_path = Path(meta_path or DEFAULT_META_NAME)
        self.store = store or default_store()
        self.entries: list[dict[str, Any]] = []
        self.pending: list[dict[str, Any]] = []  # secret requests awaiting the owner
        self.declined: set[str] = set()  # "agent_id::name" — do not ask again
        self.unlocked_until: float = 0.0
        self.integrity_ok: bool = True
        self.integrity_detail: str = ""
        self._load()

    # -- unlock session (human operator) -------------------------------------
    def is_unlocked(self) -> bool:
        return _now() < float(self.unlocked_until or 0)

    def mark_unlocked(self, ttl: float = UNLOCK_TTL_SEC) -> float:
        self.unlocked_until = _now() + float(ttl)
        return self.unlocked_until

    def touch_unlock(self, ttl: float = UNLOCK_TTL_SEC) -> float:
        """Extend the session on activity while unlocked."""
        if self.is_unlocked():
            return self.mark_unlocked(ttl)
        return self.unlocked_until

    def lock(self) -> None:
        self.unlocked_until = 0.0

    def require_unlocked(self) -> None:
        if not self.is_unlocked():
            raise PermissionError("vault is locked — authenticate to unlock")

    # -- HMAC integrity on metadata ------------------------------------------
    def _hmac_key(self) -> bytes:
        raw = self.store.get(HMAC_KEY_NAME)
        if not raw:
            raw = secrets.token_hex(32)
            self.store.set(HMAC_KEY_NAME, raw)
        return raw.encode("utf-8") if isinstance(raw, str) else bytes(raw)

    def _canonical_body(self) -> str:
        payload = {
            "secrets": [self._clean_meta(e) for e in self.entries],
            "pending": list(self.pending),
            "declined": sorted(self.declined),
        }
        return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

    def _compute_hmac(self) -> str:
        dig = hmac.new(self._hmac_key(), self._canonical_body().encode("utf-8"), hashlib.sha256)
        return dig.hexdigest()

    def verify_integrity(self) -> bool:
        return bool(self.integrity_ok)

    # -- persistence (metadata only) -----------------------------------------
    def _load(self) -> None:
        self.entries = []
        self.pending = []
        self.declined = set()
        self.integrity_ok = True
        self.integrity_detail = ""
        if not self.meta_path.is_file():
            return
        try:
            raw = json.loads(self.meta_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            log.warning("vault meta unreadable: %s", exc)
            self.integrity_ok = False
            self.integrity_detail = f"unreadable: {exc}"
            return
        stored_hmac = ""
        if isinstance(raw, dict):
            stored_hmac = str(raw.get("hmac") or "")
            for item in raw.get("secrets") or []:
                if isinstance(item, dict) and item.get("name"):
                    self.entries.append(self._clean_meta(item))
            for item in raw.get("pending") or []:
                if isinstance(item, dict) and item.get("name"):
                    self.pending.append(dict(item))
            for key in raw.get("declined") or []:
                self.declined.add(str(key))
        elif isinstance(raw, list):
            for item in raw:
                if isinstance(item, dict) and item.get("name"):
                    self.entries.append(self._clean_meta(item))
        # Verify HMAC when present; missing hmac on fresh file is OK (will be written on save).
        if stored_hmac:
            try:
                expect = self._compute_hmac()
            except Exception as exc:
                self.integrity_ok = False
                self.integrity_detail = f"hmac key error: {exc}"
                return
            if not hmac.compare_digest(stored_hmac, expect):
                self.integrity_ok = False
                self.integrity_detail = "metadata HMAC mismatch — ACL file may have been tampered with"
                log.warning("vault integrity: %s", self.integrity_detail)

    def _save(self) -> None:
        body = {
            "secrets": [self._clean_meta(e) for e in self.entries],
            "pending": list(self.pending),
            "declined": sorted(self.declined),
        }
        try:
            body["hmac"] = self._compute_hmac()
            self.integrity_ok = True
            self.integrity_detail = ""
        except Exception as exc:
            log.warning("vault hmac skipped on save: %s", exc)
            body["hmac"] = ""
        tmp = self.meta_path.with_suffix(self.meta_path.suffix + ".tmp")
        tmp.write_text(json.dumps(body, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        try:
            os.chmod(tmp, 0o600)
        except OSError:
            pass
        tmp.replace(self.meta_path)
        try:
            os.chmod(self.meta_path, 0o600)
        except OSError:
            pass

    @staticmethod
    def _clean_meta(item: dict[str, Any]) -> dict[str, Any]:
        agents = item.get("agents", [])
        if agents != "all" and not isinstance(agents, list):
            agents = []
        return {
            "name": str(item.get("name", "")),
            "description": str(item.get("description", "")),
            "agents": agents if agents == "all" else [str(a) for a in agents],
            "created_at": float(item.get("created_at") or 0),
            "last_used_at": float(item.get("last_used_at") or 0),
        }

    def list_meta(self) -> list[dict[str, Any]]:
        return [dict(e) for e in self.entries]

    def list_public(self) -> list[dict[str, str]]:
        """Names + descriptions only (safe while locked)."""
        return [{"name": e["name"], "description": str(e.get("description") or "")} for e in self.entries]

    def set_agents(self, name: str, agents: Any) -> dict[str, Any]:
        n = validate_name(name)
        meta = self.get_meta(n)
        if not meta:
            raise KeyError(f"unknown secret '{n}'")
        if agents == "all" or agents is True:
            meta["agents"] = "all"
        elif agents is None:
            meta["agents"] = []
        elif isinstance(agents, list):
            meta["agents"] = [str(a) for a in agents]
        else:
            meta["agents"] = [str(agents)]
        self.entries = [e for e in self.entries if e["name"] != n]
        self.entries.append(self._clean_meta(meta))
        self._save()
        return self.get_meta(n) or {}

    def get_meta(self, name: str) -> dict[str, Any] | None:
        n = str(name)
        for e in self.entries:
            if e["name"] == n:
                return dict(e)
        return None

    def agent_may_use(self, name: str, agent_id: str) -> bool:
        meta = self.get_meta(name)
        if not meta:
            return False
        agents = meta.get("agents")
        if agents == "all":
            return True
        return agent_id in (agents or [])

    def secrets_for_agent(self, agent_id: str) -> list[dict[str, str]]:
        """Names + descriptions only for secrets the agent may use."""
        out: list[dict[str, str]] = []
        for e in self.entries:
            if self.agent_may_use(e["name"], agent_id):
                out.append({"name": e["name"], "description": e.get("description", "")})
        return out

    def env_for_agent(self, agent_id: str) -> dict[str, str]:
        """Resolve allowed secret VALUES for process env. Touch last_used."""
        env: dict[str, str] = {}
        changed = False
        for e in self.entries:
            if not self.agent_may_use(e["name"], agent_id):
                continue
            val = self.store.get(e["name"])
            if val is None:
                log.warning("vault: missing keychain value for %s (metadata only)", e["name"])
                continue
            env[e["name"]] = val
            e["last_used_at"] = _now()
            changed = True
        if changed:
            self._save()
        return env

    def all_values_for_scrub(self) -> list[str]:
        """Load every stored value for output scrubbing. Failures skipped."""
        vals: list[str] = []
        for e in self.entries:
            try:
                v = self.store.get(e["name"])
            except Exception:
                continue
            if v and len(v) >= 4:  # skip tiny tokens that would over-redact
                vals.append(v)
        return vals

    def scrub(self, text: str, extra_values: list[str] | None = None) -> str:
        if not text:
            return text
        values = list(extra_values or []) + self.all_values_for_scrub()
        # Longest first so partial overlaps redact fully
        values.sort(key=len, reverse=True)
        out = text
        for v in values:
            if v and v in out:
                out = out.replace(v, "[REDACTED]")
        return out

    def add_secret(
        self,
        name: str,
        value: str,
        description: str = "",
        agents: Any = None,
    ) -> dict[str, Any]:
        n = validate_name(name)
        if not value:
            raise ValueError("secret value required")
        if agents is None:
            agents = []
        if agents != "all" and not isinstance(agents, list):
            agents = [str(agents)]
        self.store.set(n, value)
        existing = self.get_meta(n)
        if existing:
            existing["description"] = description or existing.get("description", "")
            existing["agents"] = agents if agents == "all" else [str(a) for a in agents]
            # replace
            self.entries = [e for e in self.entries if e["name"] != n]
            self.entries.append(self._clean_meta(existing))
        else:
            self.entries.append(self._clean_meta({
                "name": n,
                "description": description,
                "agents": agents,
                "created_at": _now(),
                "last_used_at": 0,
            }))
        self._save()
        return self.get_meta(n) or {}

    def grant(self, name: str, grantee: str) -> dict[str, Any]:
        n = validate_name(name)
        meta = self.get_meta(n)
        if not meta:
            raise KeyError(f"unknown secret '{n}'")
        g = str(grantee).strip()
        if not g:
            raise ValueError("grantee required")
        if g == "all":
            meta["agents"] = "all"
        else:
            agents = meta.get("agents")
            if agents == "all":
                pass
            else:
                lst = list(agents or [])
                if g not in lst:
                    lst.append(g)
                meta["agents"] = lst
        self.entries = [e for e in self.entries if e["name"] != n]
        self.entries.append(self._clean_meta(meta))
        self._save()
        return self.get_meta(n) or {}

    def revoke(self, name: str, grantee: str) -> dict[str, Any]:
        n = validate_name(name)
        meta = self.get_meta(n)
        if not meta:
            raise KeyError(f"unknown secret '{n}'")
        g = str(grantee).strip()
        if g == "all":
            meta["agents"] = []
        else:
            agents = meta.get("agents")
            if agents == "all":
                # Narrow from all to empty except we can't list everyone — set to []
                meta["agents"] = []
            else:
                meta["agents"] = [a for a in (agents or []) if a != g]
        self.entries = [e for e in self.entries if e["name"] != n]
        self.entries.append(self._clean_meta(meta))
        self._save()
        return self.get_meta(n) or {}

    def remove(self, name: str) -> None:
        n = validate_name(name)
        self.store.delete(n)
        self.entries = [e for e in self.entries if e["name"] != n]
        self.pending = [p for p in self.pending if p.get("name") != n]
        self._save()

    # -- pending requests (any agent → the owner) ---------------------------------
    def decline_key(self, agent_id: str, name: str) -> str:
        return f"{agent_id}::{name}"

    def was_declined(self, agent_id: str, name: str) -> bool:
        return self.decline_key(agent_id, name) in self.declined

    def add_request(
        self,
        agent_id: str,
        name: str,
        label: str = "",
        description: str = "",
    ) -> dict[str, Any]:
        n = validate_name(name)
        if self.was_declined(agent_id, n):
            raise PermissionError("request previously declined; do not ask again")
        # Replace existing pending for same agent+name
        self.pending = [
            p for p in self.pending
            if not (p.get("agent_id") == agent_id and p.get("name") == n)
        ]
        req = {
            "request_id": f"vault_{int(_now() * 1000)}_{agent_id}_{n}",
            "agent_id": agent_id,
            "name": n,
            "label": label or n,
            "description": description,
            "created_at": _now(),
        }
        self.pending.append(req)
        self._save()
        return req

    def get_pending(self, request_id: str) -> dict[str, Any] | None:
        for p in self.pending:
            if p.get("request_id") == request_id:
                return dict(p)
        return None

    def submit_request(self, request_id: str, value: str) -> dict[str, Any]:
        req = self.get_pending(request_id)
        if not req:
            raise KeyError("unknown or expired vault request")
        meta = self.add_secret(
            req["name"],
            value,
            description=str(req.get("description") or req.get("label") or ""),
            agents=[req["agent_id"]],
        )
        self.pending = [p for p in self.pending if p.get("request_id") != request_id]
        self._save()
        return {"meta": meta, "request": req}

    def dismiss_request(self, request_id: str) -> dict[str, Any] | None:
        req = self.get_pending(request_id)
        if not req:
            return None
        self.pending = [p for p in self.pending if p.get("request_id") != request_id]
        self.declined.add(self.decline_key(str(req["agent_id"]), str(req["name"])))
        self._save()
        return req


def format_vault_system_addon(vault: OfficeVault | None, agent_id: str, *, is_cos: bool = False) -> str:
    """Append to agent system prompt: names/descriptions only; never values."""
    if vault is None:
        return ""
    lines: list[str] = []
    allowed = vault.secrets_for_agent(agent_id)
    if allowed:
        lines.append(
            "Vault secrets available to you as environment variables "
            "(values are injected into your process; never ask to see the value, never print it):"
        )
        for s in allowed:
            desc = s.get("description") or "(no description)"
            lines.append(f"  - ${s['name']}: {desc}")
    lines.append(
        "To request a new secret you need, call the MCP tool request_secret(name, label, description). "
        "The owner will type the value into a masked field. You are told only that the env var is available. "
        "If the owner declines, do not request that secret again."
    )
    if is_cos:
        lines.append(
            "As Chief of Staff you manage vault access (metadata only): vault_list, vault_grant, "
            "vault_revoke, vault_request_remove. You must NEVER read, display or set secret values. "
            "Removing a secret always requires the owner's confirmation."
        )
    return "\n".join(lines)

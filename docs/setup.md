# Setup

First-run checklist for Agentic Corporation (Agent Office). Keep this repo free of private credentials — the Vault and Keychain hold secrets, not git.

## Prerequisites

| Need | Notes |
|---|---|
| **OS** | macOS (primary), Linux, or Windows with a Godot 4 build |
| **Python** | **3.10+** (the launcher picks the newest `python3.x` it finds) |
| **Godot** | **4.3+** standard (non-.NET) build from [godotengine.org](https://godotengine.org/download). Tested on 4.3-stable and 4.7.x. Put `godot` on your `PATH` (macOS: `brew install --cask godot`, or point at `Godot.app/Contents/MacOS/Godot`). |
| **Claude Code** (live agents) | Install the `claude` CLI, run `claude` once and complete `/login` so Keychain auth works. |
| **Optional** | Tailscale (to expose MCP over Funnel), `keyring` on Linux for Vault |

## Ports

| Port | Service |
|---|---|
| **8765** | Godot ↔ harness WebSocket (`ws://127.0.0.1:8765`) |
| **8766** | MCP HTTP connector (`http://127.0.0.1:8766/mcp`) |

Only expose 8766 if you intentionally funnel MCP. Leave 8765 on localhost.

## One-shot macOS launch

Double-click **`run-mac.command`** (or run it from Terminal). It will:

1. Create `.venv` on first run and `pip install -r requirements.txt` (reinstalls when that file changes).
2. Start the harness bridge with the MCP connector on **8766**.
3. Print where the MCP token file lives (`.office_token`, gitignored).
4. Open the Godot client; the bridge stops when you close the game.

## Manual harness

```bash
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt    # websockets>=13
python agent_harness.py --mode live --mcp --office office.json
```

Useful flags: `--host` / `--port` (default `127.0.0.1` / `8765`), `--mcp-port 8766`, `--tempo calm|busy`, `--no-ambient`.

## Live agent commands (`agent_cmds.json`)

Copy the example and edit (the real file is gitignored):

```bash
cp agent_cmds.example.json agent_cmds.json
```

Bind each live `agent_id` to a CLI. Typical Claude Code print-mode shape:

```json
{
  "chief_of_staff": ["claude", "-p"]
}
```

Without bindings, dashboard prompts land in the MCP inbox and nothing executes them.

## Godot client

1. Godot **Project Manager → Import →** select `project.godot` in this folder → **Import & Edit**.
2. Press Play. The top bar shows connection status (retries with backoff).
3. CLI alternative: `godot --path .`

If you switch the same checkout between Godot 4.3 and 4.4+, re-run `godot --headless --path . --import` with the version you are about to use (class caches differ).

## Office features (what you should see)

- **Hex hub** with Break Room, Canteen (Notice Board), Rec Room, Meeting Room, Server Room (knowledge + Vault safe).
- **Hiring Board** (+ Add Agent): 51 seeded roles including EA; single Chief of Staff.
- **Kill Agent** mode + `/fire-preview` animation previews.
- Terminal: `/jd`, `/msg`, `/verbose`|`/quiet`, `/kb`, `/notices`, `/vault`, plus **ask_human** cards from agents.
- Server Room knowledge library under `knowledge/` with `INDEX.md`.

## Vault (secrets)

See the [Vault](../README.md#vault) section in the README. Short version:

- Values → OS keychain only; `.office_vault.json` is metadata (gitignored).
- `/vault` commands and the Server Room safe for the human operator.
- Agents: `request_secret`; Chief of Staff: ACL tools (never values).
- Harness injects granted names as env vars and scrubs values from logs/CLI output.

## Security reminders

- Do not commit `.office_token`, `.office_vault.json`, `agent_cmds.json` secrets, or API keys.
- `.gitleaks.toml` is available for pre-push scanning.
- Prefer the Vault over pasting credentials into prompts or `office.json`.

## Office Vault unlock (macOS)

The Executive bank safe sends `VAULT_UNLOCK` to the harness. On macOS the harness runs `tools/vault_unlock`, a small Swift helper using **LocalAuthentication** (`.deviceOwnerAuthentication`):

- Touch ID when enrolled
- Otherwise the Mac login password dialog
- Build once: `swiftc -O -o tools/vault_unlock tools/vault_unlock.swift -framework LocalAuthentication`
- The helper is built automatically on first unlock if `swiftc` is available

On Linux/Windows the harness touches a keyring sentinel instead (desktop keyring prompt). The vault re-locks after 2 minutes idle or when the Safe UI is closed. Metadata HMAC uses a Keychain-held key named `__VAULT_HMAC_KEY__`.


## /lite ops view and NEEDS_YOU

The harness serves a phone-friendly ops list at **http://127.0.0.1:8787/lite**
(override with `--lite-port` / `--lite-host`). Over Tailscale:
`tailscale serve --bg 8787` or Funnel, then open `http://<magicdns>:8787/lite`.

When an agent awaits input, the 2D client shows a red desk beacon and a top
banner. Press **N** to cycle waiting agents. Live launches also enable
`--worktrees` (per-agent git checkouts under `.agent_worktrees/`) and
`--stream-json` (live thinking/tool poses; text remains the fallback).

Feature ideas (needs-you, worktrees, agents-manage-agents, /lite) inspired by
AgentSystemLabs/agent-office (MIT) — see `CREDITS.md`.

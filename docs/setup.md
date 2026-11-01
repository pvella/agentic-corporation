# Setup

First-run checklist for Agentic Corporation (Agent Office). Keep this repo free of private credentials — the Vault and Keychain hold secrets, not git.

## Quick path for a new user (macOS)

1. Install the prerequisites below (Python 3.10+, Godot 4.3+, Claude Code).
2. `claude`, then `/login` with **your** claude.ai account.
3. Optional: connect **Microsoft 365** or **Google Calendar** at claude.ai → Settings → Connectors so the EA and Chief of Staff can read your calendar.
4. Optional: put your name in `office.json` as `"owner": {"name": "Jane"}` (otherwise `git config user.name` is used).
5. `cp agent_cmds.example.json agent_cmds.json` to run the agents live with Claude Code (required before live; `run-mac.command --mode live` also auto-copies the example when missing, and the harness Setup check warns if 0 agents are Claude-bound).
6. Double-click `run-mac.command` and read the **Setup check** it prints.
7. In the office, ask the Chief of Staff something ("What's the weather today?"), and tell it where you are; it saves that to the office memory.

## Prerequisites

| Need | Notes |
|---|---|
| **OS** | macOS (primary), Linux, or Windows with a Godot 4 build |
| **Python** | **3.10+** (the launcher picks the newest `python3.x` it finds) |
| **Godot** | **4.3+** standard (non-.NET) build from [godotengine.org](https://godotengine.org/download). Tested on 4.3-stable and 4.7.x. Put `godot` on your `PATH` (macOS: `brew install --cask godot`, or point at `Godot.app/Contents/MacOS/Godot`). |
| **Claude Code** (live agents) | Install the `claude` CLI, run `claude` once and complete `/login` with a **claude.ai** account (an API key alone runs agents but gives no claude.ai connectors, so no calendar). |
| **Calendar** (optional) | Microsoft 365 or Google Calendar connected at claude.ai → Settings → Connectors. A company admin may need to approve it. |
| **Optional** | Tailscale (to expose MCP over Funnel), `keyring` on Linux for Vault (installed automatically on Windows) |

## Ports

| Port | Service |
|---|---|
| **8765** | Godot ↔ harness WebSocket (`ws://127.0.0.1:8765`) |
| **8766** | MCP HTTP connector (`http://127.0.0.1:8766/mcp`) |
| **8787** | `/lite` phone-friendly ops view |

Only expose 8766 if you intentionally funnel MCP. Leave 8765 on localhost.

## One-shot macOS launch

Double-click **`run-mac.command`** (or run it from Terminal). It will:

1. Create `.venv` on first run and `pip install -r requirements.txt` (reinstalls when that file changes).
2. Start the harness bridge with the MCP connector on **8766** (live mode, worktrees and stream-json when `agent_cmds.json` exists).
3. Print where the MCP token file lives (`.office_token`, generated per machine, gitignored).
4. A few seconds later the bridge prints a **Setup check**:

   ```
   Setup check
     Owner: Jane (from git config user.name)
     Claude Code: logged in via claude.ai
     Calendar connector: claude_ai_Microsoft_365
   ```

   Anything missing gets a `WARNING:` line saying how to fix it (not logged in, API-key login, no calendar connector or one that still needs sign-in, no owner name). Run `.venv/bin/python office_setup.py` for the same check without starting the office.
5. Open the Godot client; the bridge stops when you close the game.

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

The file's presence is what matters: with it, **every agent on the roster (and every new hire) is bound to Claude Code automatically**, with a system prompt built from its job description in `office.json`. Add an entry only to override one agent:

```json
{
  "chief_of_staff": {"cmd": "claude -p --output-format text {prompt}", "cwd": "."}
}
```

Entries for agents that aren't on the roster (fired agents, sample ids) are ignored with a warning. Without the file, dashboard prompts land in the MCP inbox and nothing executes them.

### What the agents may do

Agents run with an allow-list and never see approval prompts; anything not listed is denied.

- **Everyone:** read files, read-only `git`/`gh`, **web search and fetch**, edit the office memory, and `message_colleague` to hand work to another agent (the answer comes back as a message).
- **EA and Chief of Staff:** read-only calendar tools from the connected calendar connector. No event changes, no email.
- **Office memory:** `.office_memory/owner.md` (gitignored, per machine). Agents add lasting facts you tell them; every prompt includes it. Review or edit it from the **Server Room** → *Office memory* → **Edit**.
- When the allow-list changes, affected agents start a fresh chat so they retry tools that were denied before.

## Godot client

1. Godot **Project Manager → Import →** select `project.godot` in this folder → **Import & Edit**.
2. Press Play. The top bar shows connection status (retries with backoff).
3. CLI alternative: `godot --path .`

If you switch the same checkout between Godot 4.3 and 4.4+, re-run `godot --headless --path . --import` with the version you are about to use (class caches differ).

## Office features (what you should see)

- **Hex hub** with Break Room, Canteen (Notice Board), Rec Room, HR (interview table, welcome area, People team desks) and Server Room (knowledge library + office memory).
- **Default roster:** Chief of Staff and EA (Executive), Developer (Engineering), Finance, Security (Special Projects).
- **Hiring Board** (+ Add Agent): 51 seeded roles; hires beam into HR, then walk to a desk in their own department (People roles stay in HR). Single Chief of Staff.
- **Kill Agent** mode + `/fire-preview` animation previews (Shift+F cycles them).
- Terminal: `/jd`, `/msg`, `/verbose`|`/quiet`, `/kb`, `/notices`, `/vault`, plus **ask_human** cards from agents.
- Server Room: knowledge library under `knowledge/` with `INDEX.md`, and the editable **Office memory** card.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Agent says web search / calendar "needs approval" | Restart the bridge so it picks up the current allow-list; agents with stale chats get a fresh one automatically. |
| EA can't see the calendar | Check the Setup check line. Connect Microsoft 365 or Google Calendar at claude.ai → Settings → Connectors, then restart. |
| Agents call you "the owner" | Set `"owner": {"name": "<you>"}` in `office.json` (or `git config user.name`), then restart. |
| Bridge exits at start | Read the first lines of its output: a bad `office.json`, or a port (8765/8766/8787) already in use. |

## Vault (secrets)

See the [Vault](../README.md#vault) section in the README. Short version:

- Values → OS keychain only; `.office_vault.json` is metadata (gitignored).
- `/vault` commands and the Executive bank safe for the human operator.
- Agents: `request_secret`; Chief of Staff: ACL tools (never values).
- Harness injects granted names as env vars and scrubs values from logs/CLI output.

## Security reminders

- Do not commit `.office_token`, `.office_vault.json`, `.office_memory/`, `agent_cmds.json` secrets, or API keys.
- `.gitleaks.toml` is available for pre-push scanning.
- Prefer the Vault over pasting credentials into prompts or `office.json`.

## Office Vault unlock (macOS)

The Executive bank safe sends `VAULT_UNLOCK` to the harness. On macOS the harness runs `tools/vault_unlock`, a small Swift helper using **LocalAuthentication** (`.deviceOwnerAuthentication`):

- Touch ID when enrolled
- Otherwise the Mac login password dialog
- Build once: `swiftc -O -o tools/vault_unlock tools/vault_unlock.swift -framework LocalAuthentication`
- The helper is built automatically on first unlock if `swiftc` is available

On Windows the harness runs `tools/vault_unlock_windows.ps1`: Windows Hello, or the Windows account password when Hello is not set up (see [windows-setup.md](windows-setup.md#secrets--vault)). On Linux it touches a keyring sentinel instead (desktop keyring prompt). The vault re-locks after 2 minutes idle or when the Safe UI is closed. Metadata HMAC uses a Keychain-held key named `__VAULT_HMAC_KEY__`.


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

# Claude Code → Agent Office hooks

Project-level adapter so a Claude Code session in this repo drives a sprite in
the Godot office via the existing MCP connector (`report_office_status`).

## What it does

`.claude/settings.json` registers async command hooks for:

| Hook | Office action |
| --- | --- |
| `SessionStart` / `UserPromptSubmit` | `start_task` |
| `PreToolUse` / `PostToolUse` | `run_tool` |
| `Notification` | `thinking` |
| `Stop` | `finish` |

Each hook runs `tools/claude_office_hook.py`, which POSTs to
`http://127.0.0.1:8766/mcp` with the bearer token from `.office_token`
(or `$OFFICE_MCP_TOKEN`).

Your global `~/.claude/settings.json` is **not** modified.

## Try it

1. Start the office (bridge + Godot), e.g. `./run-mac.command --mode live`.
2. In this repo: `claude -p 'list files in this repo'`
   (or an interactive `claude` session).
3. Watch **Chief of Staff** (override with `$OFFICE_AGENT`).

Optional env: `OFFICE_MCP_URL`, `OFFICE_AGENT`, `OFFICE_HOOK_LOG`,
`OFFICE_HOOK_QUIET=1` (log only).

Failures are ignored so a down bridge never blocks Claude Code.

## Vault and live agents

When the harness runs in live/cli mode, granted Vault secrets are injected into the Claude process environment as `$NAME`. Do not echo secret values in tool output; the harness scrubs known values from captured logs, but avoiding prints is best. Request new secrets with the `request_secret` MCP tool (masked card in the office). The Chief of Staff manages ACLs via `vault_list` / `vault_grant` / `vault_revoke` / `vault_request_remove` without ever seeing values.

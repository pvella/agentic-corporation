## Vault (`feature/vault`)

- Shared bot secrets: values in macOS Keychain (`agentic-corp.<NAME>`) / Linux secure store; gitignored `.office_vault.json` metadata only
- `/vault` terminal commands + Server Room VaultDoor; notice board events (names only)
- Any agent `request_secret` → masked Godot card; CoS `vault_*` MCP tools; remove needs human confirm
- CliRunner env injection + scrub of harness/CLI output; system-prompt names/descriptions only
- README + hooks doc cover hex hub, Rec/Hiring/Kill/KB/meeting/`/msg`/quiet/`/notices`/`/jd`/vault

# Agent Office — change notes (for PRs)

## Why agents do not pick up tasks (root cause)

In `--mode live` without `--agent-cmd` / `agent_cmds.json`, typing a task in a sprite terminal **queues it to the MCP inbox**. Nothing executes it until a real bot calls `check_office_inbox`. Claude Code hooks only *report* status into the office (one-way). Fix: bind sprites in `agent_cmds.json` (see `agent_cmds.example.json`); `run-mac.command` loads it automatically.

## Live Claude bridge (`feature/live-claude-bridge`)

- `--agent-cmds-file` / `agent_cmds.json` bindings
- Per-agent cwd + `OFFICE_AGENT` env for CLI runners
- Inbox warning when unbound in live/cli
- `run-mac.command` auto-loads `agent_cmds.json`

## Org reorg + canteen + hire/fire (`feature/office-reorg-canteen-hire-fire`)

- PTC wing removed; rooms: Executive, Engineering, Product & Design, Operations & Support, Finance, Special Projects
- New hires: 3D Modeller, Trailer Studio, Community3008 Odoo, Alma Doepel; DR eggbot = Recruiter / HR
- Shared Canteen with lunch idle behaviour (12–14 local)
- Hire FX: beam + sparkles + materialise; Fire FX: cartoon collapse + medics + stretcher + clear desk
- Triggers: harness `HIRE_AGENT` / `FIRE_AGENT`/`ARCHIVE_AGENT` / `PREVIEW_HIRE_FIRE`; drawer Archive + recruiter Hire…; Shift+H/F/B; `--preview-hire` etc.

## Quiet terminal + every-agent Claude (same PR)

- Terminal shows `you> …` then the reply only (no inbox/queue ACK chatter)
- All roster agents bound in `agent_cmds.example.json` to `claude -p` with short role system prompts
- Per-agent Claude sessions under `.office_claude/<agent_id>/` (`--continue` + `--add-dir` project)
- Canteen restyle: serving counter + sneeze guard + food trays, drinks fridge, coffee, microwave, menu board, bin, long tables with place settings; plate in front of eating agents

## Quiet terminal + verbose toggle + real hire/archive

- Default terminal is quiet: only `> message`, then `…`, then the reply (no tool/queue/harness chatter)
- `/verbose` or Shift+V shows tool/queue detail; `/quiet` returns to quiet
- Claude bindings get a read-only `--allowedTools` allowlist (Read/Grep/Glob + git status/log/diff + gh pr list/view) and `--permission-prompts none` so status questions do not hang on approvals
- Recruiter (DR eggbot) **Hire…** then `/hire Name | Role` persists to `office.json` and binds Claude; **Archive** on another bot persists removal


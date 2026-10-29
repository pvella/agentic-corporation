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

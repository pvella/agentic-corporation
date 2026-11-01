## Office MCP allowlist for live Claude (`--permission-prompts none`)

- Cause: live Claude runs only auto-allowed `mcp__office__message_colleague`, so with `--permission-prompts none` roster/inbox calls (`list_agents`, `check_office_inbox`, …) were denied and CoS reported “needs approval”.
- Fix: extend `OFFICE_MCP_TOOLS` to the bridge tools agents need (`report_office_status`, `check_office_inbox`, `reply_office_message`, `message_colleague`, `list_agents`, `request_secret`). Still no hire/fire/vault-admin and no `bypassPermissions`.

## agent_cmds live bindings (Windows + Mac)

- Docs: `docs/windows-setup.md` now has an explicit numbered step to `copy agent_cmds.example.json agent_cmds.json` before the first live launch; macOS `docs/setup.md` step 5 notes the same requirement.
- `run-windows.ps1` / `run-mac.command`: in `--mode live`, auto-copy `agent_cmds.example.json` -> `agent_cmds.json` when the file is missing, and warn if bindings are still absent.
- Harness Setup check + startup log warn when live mode has **0 agents bound to Claude**.
- Windows: `_split_cli_cmd` uses `shlex.split(..., posix=False)` so absolute `claude.exe` paths with backslashes are not mangled.

## Windows launcher and test fixes (`feature/windows-vault`)

- `run-windows.ps1` waits for the Godot window with `Start-Process -Wait`, so the harness only stops when you close the game (calling `& $godot` could return early and kill the bridge).
- Find-Godot also looks under the WinGet Packages folder after `winget install GodotEngine.GodotEngine`.
- First-time import counts as success if `.godot/global_script_class_cache.cfg` exists (Godot sometimes exits non-zero after writing it).
- MCP tests on Windows use the Selector event loop, close leftover WebSocket clients on teardown, and the harness awaits `server.wait_closed()` so pytest no longer hangs on Proactor/IOCP.
- Feature tests read `Main.gd` / `Agent.gd` as UTF-8; Unix `0o600` mode asserts are skipped on Windows; CliHelper PATH checks use `Path` so they work with Windows separators.
- Docs: `docs/windows-setup.md` and the README Windows shortcut cover winget Godot, native Claude Code install (WSL-only Claude is not used), first import, tests, and live mode, in plain ASCII.

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

- Separate wing removed; rooms: Executive, Engineering, Product & Design, Operations & Support, Finance, Special Projects
- New hires: 3D Modeller, Trailer Studio, Community ERP; a recruiter role for HR
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


## Windows support (`feature/windows-support`)

- `run-windows.bat` / `run-windows.ps1`: venv, first-time Godot import, harness + MCP :8766, Godot; single-instance guard on port 8765
- Cross-platform CLI env (`HOME`/`USERPROFILE`, `USER`/`USERNAME`) and process teardown (`terminate` without `killpg` on Windows); resolve `claude.cmd` via `cmd.exe /c`
- `export_presets.cfg` Windows Desktop preset → `build/AgentOffice.windows.x86_64.exe`
- Docs: [docs/windows-setup.md](docs/windows-setup.md); README quick start / components / limitations
- Vault secret storage on Windows (Credential Manager via `keyring`) is out of scope here — lands with the vault PR

## Windows vault (`feature/windows-vault`)

- `keyring` added to `requirements.txt` for Windows; values go to Credential Manager. Without it the vault refuses to store values (`UnavailableStore`) instead of falling back to plaintext files, since `chmod 0600` does nothing on Windows
- `KeyringStore` splits values over 600 chars across `<NAME>.partN` entries with a SHA-256 checked header (Credential Manager's 2560-byte blob limit); existing short/unchunked values read unchanged
- Unlock: `tools/vault_unlock_windows.ps1`: Windows Hello via `IUserConsentVerifierInterop` (prompt owned by the Godot window), falling back to a CredUI password prompt checked with `LogonUser` against the current user's SID. Previously Windows "unlock" always succeeded with no check
- `tools/vault_auth.py --password` exercises the fallback; tests in `tests/test_windows_vault.py`

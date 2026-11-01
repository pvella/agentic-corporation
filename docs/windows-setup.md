# Windows setup

Run Agentic Corporation (Agent Office) on Windows 10/11. You still need the Python harness and a Godot 4.3+ editor (or an exported `.exe`); there is no store build yet.

## Prerequisites

1. **Python 3.10+** from [python.org](https://www.python.org/downloads/). During setup, tick **Add python.exe to PATH**. Confirm with:

   ```bat
   python --version
   ```

2. **Godot 4.3 or newer** (standard / non-.NET build) from [godotengine.org/download/windows](https://godotengine.org/download/windows/). Either:
   - rename the binary to `godot.exe` and put it on your PATH, or
   - leave it as `Godot_v*-stable_win64.exe` in Downloads / Local Programs — `run-windows.ps1` looks there.

3. **Git** (optional but useful) from [git-scm.com](https://git-scm.com/download/win).

4. **Claude Code** (only if you want live agents, not mock mode):

   ```bat
   npm install -g @anthropic-ai/claude-code
   claude
   ```

   Complete `/login` once in that terminal. On Windows the CLI is often `claude.cmd`; the harness resolves `.cmd` / `.bat` through `cmd.exe /c`. Copy `agent_cmds.example.json` to `agent_cmds.json` (gitignored) when you are ready to bind sprites to Claude; every roster agent is then bound automatically.

   Log in with a **claude.ai** account if you want calendar access, connect Microsoft 365 or Google Calendar at claude.ai → Settings → Connectors, and set `"owner": {"name": "<you>"}` in `office.json`. The bridge prints a **Setup check** at start; see [setup.md](setup.md#quick-path-for-a-new-user-macos) for the same steps on macOS and what the agents may do.

## Launch (recommended)

From a checkout of this repo:

```bat
run-windows.bat
```

Or in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-windows.ps1
```

You can pass harness flags through:

```bat
run-windows.bat --mode live
```

What the launcher does:

- refuses to start if port **8765** is already in use (keeps a single harness)
- creates `.venv` and installs `requirements.txt` when needed (Python 3.10+)
- runs a one-time `godot --headless --import` if `.godot/` is missing
- starts `agent_harness.py` with MCP on **8766** and loads `agent_cmds.json` when present
- opens Godot; when you close the window it stops the harness

## Manual launch

```bat
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt

python agent_harness.py --mcp-port 8766
```

In another terminal:

```bat
godot --path .
```

## Exporting a Windows `.exe`

1. Install **export templates** that match your Godot version (Editor → Manage Export Templates, or download the `.tpz` from the [Godot archive](https://godotengine.org/download/archive/) and install it).
2. This repo ships a **Windows Desktop** preset in `export_presets.cfg` (output `build/AgentOffice.windows.x86_64.exe`, PCK embedded).
3. From the editor: **Project → Export → Windows Desktop → Export Project**.
4. From the CLI (templates must already be installed):

   ```bat
   mkdir build
   godot --headless --path . --export-release "Windows Desktop" build\AgentOffice.windows.x86_64.exe
   ```

The exported game still needs the Python harness running on the same machine (`run-windows.bat` or `python agent_harness.py`). The `.exe` is only the Godot client.

Cross-compiling the Windows binary from Linux/macOS works the same way once the Windows export templates for that Godot version are installed under the editor’s export-templates folder.

## Secrets / vault (when present)

A shared vault feature (separate PR) stores secret *values* outside the repo. On Windows that uses the **Windows Credential Manager** through Python’s `keyring` package. Until that lands, do not put API keys in `agent_cmds.json` or the repo; keep Claude logged in via its own config (`~/.claude.json` / `%USERPROFILE%\.claude.json`).

## Tailscale Funnel

`tools/funnel-mac.sh` is macOS-oriented. On Windows, install Tailscale and run Funnel yourself against port 8766, for example:

```bat
tailscale funnel --bg 8766
tailscale funnel status
```

## Troubleshooting

| Symptom | What to try |
|---|---|
| `godot not found` | Add Godot to PATH or place `Godot_v*-stable_win64.exe` under `%LOCALAPPDATA%\Programs\Godot\` or Downloads. |
| `Port 8765 is already in use` | Another harness is running. Close that Agent Office window or end the python process. |
| Blank / green Godot window | Delete `.godot` and re-run the launcher (first import), or open the project once in the editor. |
| `claude` / Not logged in | Run `claude` in a normal terminal and `/login`. Confirm `%USERPROFILE%\.claude.json` exists. |
| Execution policy blocks `.ps1` | Use `run-windows.bat`, or `powershell -ExecutionPolicy Bypass -File .\run-windows.ps1`. |

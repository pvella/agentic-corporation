# Windows setup

Run Agentic Corporation (Agent Office) on Windows 10/11. You still need the Python harness and a Godot 4.3+ editor (or an exported `.exe`); there is no store build yet.

## Prerequisites

1. **Python 3.10+** from [python.org](https://www.python.org/downloads/). During setup, tick **Add python.exe to PATH**. Confirm with:

   ```bat
   python --version
   ```

2. **Godot 4.3 or newer** (standard / non-.NET build). Easiest:

   ```bat
   winget install GodotEngine.GodotEngine
   ```

   `run-windows.ps1` finds the WinGet package under `%LOCALAPPDATA%\Microsoft\WinGet\Packages\`, plus `%LOCALAPPDATA%\Programs\Godot\`, Downloads, Scoop, and `godot` on PATH. You can also download from [godotengine.org/download/windows](https://godotengine.org/download/windows/) and leave `Godot_v*-stable_win64.exe` in one of those folders.

3. **Git** (optional but useful) from [git-scm.com](https://git-scm.com/download/win).

4. **Claude Code** (only if you want live agents, not mock mode). Install the **native Windows** build so `claude` is on your Windows PATH:

   ```powershell
   irm https://claude.ai/install.ps1 | iex
   ```

   That puts `claude.exe` in `%USERPROFILE%\.local\bin`. Add that folder to your user PATH if the installer says it is missing, then open a **new** terminal and check:

   ```bat
   claude --version
   ```

   Or, if you already have Node.js:

   ```bat
   npm install -g @anthropic-ai/claude-code
   ```

   A Claude install that exists **only inside WSL** is not visible to the harness. Install (or also install) on Windows as above.

   Then log in once (you do this yourself; the office does not store your Claude password):

   ```bat
   claude
   ```

   In that session run `/login` with your claude.ai account. For calendar connectors, connect Microsoft 365 or Google Calendar at claude.ai > Settings > Connectors, and set `"owner": {"name": "<you>"}` in `office.json`. See [setup.md](setup.md#quick-path-for-a-new-user-macos) for the same ideas on macOS.

## Launch (recommended)

From a checkout of this repo (mock mode by default):

```bat
run-windows.bat
```

Or in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-windows.ps1
```

### Live mode (real Claude agents)

Do these steps **before** the first live launch:

1. Install and `/login` Claude Code (prerequisites above). Confirm `%USERPROFILE%\.claude.json` exists.
2. **Copy bindings:** from the repo root run:

   ```bat
   copy agent_cmds.example.json agent_cmds.json
   ```

   `agent_cmds.json` is gitignored. Without it, live prompts sit in the MCP inbox and sprites never call Claude. (`run-windows.ps1 --mode live` also auto-copies the example when the file is missing, and the harness Setup check warns if 0 agents are Claude-bound.)
3. Optional: set `"owner": {"name": "<you>"}` in `office.json`, and connect calendar connectors at claude.ai > Settings > Connectors.
4. Launch:

   ```bat
   run-windows.bat --mode live
   ```

What the launcher does:

- refuses to start if port **8765** is already in use (keeps a single harness)
- creates `.venv` and installs `requirements.txt` when needed (Python 3.10+)
- first launch: runs `godot --headless --import` if `.godot/global_script_class_cache.cfg` is missing (Godot may exit non-zero; the cache file is what counts)
- starts `agent_harness.py` with MCP on **8766**, lite on **8787**, and loads `agent_cmds.json` when present
- opens Godot with `Start-Process -Wait` so the harness stays up until you close the window, then stops the bridge

## Tests on Windows

```bat
.venv\Scripts\activate
python -m pip install -r requirements.txt pytest pytest-timeout
python -m pytest tests/ -q --timeout=60
```

Do not rely on `PYTHONUTF8=1` for the suite; tests that read `.gd` files pass an explicit UTF-8 encoding. Unix file-mode checks (`0o600`) are skipped on Windows.

## Manual launch

```bat
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt

python agent_harness.py --mcp-port 8766 --lite-port 8787
```

In another terminal:

```bat
godot --path .
```

## Exporting a Windows `.exe`

1. Install **export templates** that match your Godot version (Editor > Manage Export Templates, or download the `.tpz` from the [Godot archive](https://godotengine.org/download/archive/) and install it).
2. This repo ships a **Windows Desktop** preset in `export_presets.cfg` (output `build/AgentOffice.windows.x86_64.exe`, PCK embedded).
3. From the editor: **Project > Export > Windows Desktop > Export Project**.
4. From the CLI (templates must already be installed):

   ```bat
   mkdir build
   godot --headless --path . --export-release "Windows Desktop" build\AgentOffice.windows.x86_64.exe
   ```

The exported game still needs the Python harness running on the same machine (`run-windows.bat` or `python agent_harness.py`). The `.exe` is only the Godot client.

Cross-compiling the Windows binary from Linux/macOS works the same way once the Windows export templates for that Godot version are installed under the editor's export-templates folder.

## Secrets / vault

The Office Vault keeps secret *values* in **Windows Credential Manager** (Control Panel > Credential Manager > Windows Credentials, entries for `agentic-corp`) through Python's `keyring` package. `keyring` is in `requirements.txt` for Windows, so `run-windows.bat` installs it. If it is missing, the vault refuses to store values instead of writing them to plain files. Values longer than 600 characters (service-account JSON, PEM keys) are split across several `<NAME>.partN` entries because Credential Manager limits each entry to 2560 bytes.

**Unlock**: clicking the Executive safe runs `tools/vault_unlock_windows.ps1`:

- **Windows Hello** (PIN, fingerprint or face) when it is set up, with the prompt attached to the Godot window
- otherwise the **Windows account password** in the standard Windows credential dialog. The password is checked with `LogonUser` and must belong to the account running the office. Each wrong password counts toward the account lockout policy, and you get three tries per unlock.
- cancelling Hello does not fall back to the password; the vault stays locked

To test without the game, run `python tools\vault_auth.py` (Hello) or `python tools\vault_auth.py --password` (password fallback). Exit code 0 means unlocked.

Keep API keys out of `agent_cmds.json` and the repo; keep Claude logged in via its own config (`%USERPROFILE%\.claude.json`).

## Tailscale Funnel

`tools/funnel-mac.sh` is macOS-oriented. On Windows, install Tailscale and run Funnel yourself against port 8766, for example:

```bat
tailscale funnel --bg 8766
tailscale funnel status
```

## Troubleshooting

| Symptom | What to try |
|---|---|
| `godot not found` | `winget install GodotEngine.GodotEngine`, or place `Godot_v*-stable_win64.exe` under `%LOCALAPPDATA%\Programs\Godot\` or Downloads. |
| `Port 8765 is already in use` | Another harness is running. Close that Agent Office window or end the python process. |
| Blank / green Godot window | Delete `.godot` and re-run the launcher (first import), or open the project once in the editor. |
| First import looked like it failed | If `.godot\global_script_class_cache.cfg` exists, import succeeded; the launcher treats that file as success. |
| `claude` not found / Not logged in | Install native Windows Claude (not WSL-only). Run `claude` in a new terminal and `/login`. Confirm `%USERPROFILE%\.claude.json` exists. |
| Execution policy blocks `.ps1` | Use `run-windows.bat`, or `powershell -ExecutionPolicy Bypass -File .\run-windows.ps1`. |
| Fancy characters look wrong in cmd | The docs are UTF-8; run `chcp 65001` or use Windows Terminal. |

#!/bin/zsh
# Double-click on macOS: starts the event bridge (WebSocket :8765 for the game,
# MCP connector :8766/mcp for live bot status) and opens the Godot client.
# The bridge stops when the game window closes.
# Extra harness flags can be passed through, e.g.  ./run-mac.command --mode live
cd "$(dirname "$0")"

# First launch (or a fresh clone): .godot/ is gitignored, so class_name
# registrations like Agent are missing until Godot imports once. Without
# that, Main.gd fails to parse and the window is a blank/green screen.
if [ ! -f .godot/global_script_class_cache.cfg ]; then
  if ! command -v godot >/dev/null; then
    echo "godot not found on PATH. Install with: brew install --cask godot" >&2
    exit 1
  fi
  echo "First-time Godot import (building .godot class cache)…"
  godot --headless --path . --import || {
    echo "Godot import failed. Try: godot --path . --editor" >&2
    exit 1
  }
fi

if [ ! -d .venv ]; then
  # The MCP connector needs Python 3.10+ (macOS's own python3 is 3.9).
  for PY in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    command -v $PY >/dev/null && break
  done
  $PY -m venv .venv
fi
# (Re)install when requirements.txt changed since the last install.
if [ ! -f .venv/.requirements.stamp ] || [ requirements.txt -nt .venv/.requirements.stamp ]; then
  .venv/bin/pip install -q -r requirements.txt && touch .venv/.requirements.stamp
fi
# Detect explicit --mode live so we can auto-copy agent_cmds when missing.
IS_LIVE_ARG=0
prev=""
for a in "$@"; do
  if [ "$a" = "live" ] || [ "$a" = "--mode=live" ]; then IS_LIVE_ARG=1; fi
  if [ "$prev" = "--mode" ] && [ "$a" = "live" ]; then IS_LIVE_ARG=1; fi
  prev="$a"
done
if [ "$IS_LIVE_ARG" = "1" ] && [ ! -f agent_cmds.json ]; then
  if [ -f agent_cmds.example.json ]; then
    cp agent_cmds.example.json agent_cmds.json
    echo "Copied agent_cmds.example.json -> agent_cmds.json (required for live Claude bindings)"
  else
    echo "WARNING: Live mode but agent_cmds.json is missing and agent_cmds.example.json was not found." >&2
  fi
fi
CMDS_FILE_ARGS=()
if [ -f agent_cmds.json ]; then
  CMDS_FILE_ARGS=(--agent-cmds-file agent_cmds.json)
  echo "CLI bindings: agent_cmds.json"
elif [ "$IS_LIVE_ARG" = "1" ]; then
  echo "WARNING: Live mode with 0 Claude bindings: create agent_cmds.json (copy from agent_cmds.example.json)." >&2
fi
# agent_cmds.json means real Claude agents — default to live unless --mode was passed.
MODE_ARGS=()
has_mode=0
for a in "$@"; do
  if [ "$a" = "--mode" ] || [[ "$a" == --mode=* ]]; then
    has_mode=1
    break
  fi
done
if [ -f agent_cmds.json ] && [ "$has_mode" -eq 0 ]; then
  MODE_ARGS=(--mode live)
  echo "Mode: live (agent_cmds.json present; pass --mode to override)"
fi
# Live builds get worktrees + stream-json poses; text remains the fallback if stream-json fails.
EXTRA_LIVE=()
# Detect live mode from MODE_ARGS or explicit --mode live in "$@"
# (zsh-safe: no ${!arr[@]} index expansion — run-mac.command is #!/bin/zsh)
IS_LIVE=0
prev=""
for a in "${MODE_ARGS[@]}" "$@"; do
  if [ "$a" = "live" ] || [ "$a" = "--mode=live" ]; then IS_LIVE=1; fi
  if [ "$prev" = "--mode" ] && [ "$a" = "live" ]; then IS_LIVE=1; fi
  prev="$a"
done
if [ "$IS_LIVE" = "1" ]; then
  EXTRA_LIVE=(--worktrees --stream-json)
  echo "Harness extras: --worktrees --stream-json"
fi
.venv/bin/python agent_harness.py --mcp-port 8766 --lite-port 8787 "${MODE_ARGS[@]}" "${CMDS_FILE_ARGS[@]}" "${EXTRA_LIVE[@]}" "$@" &
BRIDGE=$!
sleep 2
if [ -n "$OFFICE_MCP_TOKEN" ]; then
  echo "MCP connector: http://127.0.0.1:8766/mcp  (token from $OFFICE_MCP_TOKEN)"
else
  echo "MCP connector: http://127.0.0.1:8766/mcp  (token in $PWD/.office_token)"
fi
echo "Lite ops view: http://127.0.0.1:8787/lite  (Tailscale: serve/funnel this port)"
echo "Public URL (if Tailscale Funnel is on): see ./tools/funnel-mac.sh status"
echo "View: 2D office  — press N to cycle NEEDS YOU agents"
godot --path .
kill $BRIDGE 2>/dev/null

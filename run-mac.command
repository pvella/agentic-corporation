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
.venv/bin/python agent_harness.py --mcp-port 8766 "$@" &
BRIDGE=$!
sleep 2
if [ -n "$OFFICE_MCP_TOKEN" ]; then
  echo "MCP connector: http://127.0.0.1:8766/mcp  (token from \$OFFICE_MCP_TOKEN)"
else
  echo "MCP connector: http://127.0.0.1:8766/mcp  (token in $PWD/.office_token)"
fi
echo "Public URL (if Tailscale Funnel is on): see ./tools/funnel-mac.sh status"
godot --path .
kill $BRIDGE 2>/dev/null

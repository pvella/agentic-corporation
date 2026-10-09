#!/bin/zsh
# Double-click on macOS: starts the event bridge and opens the Godot client.
# The bridge stops when the game window closes.
cd "$(dirname "$0")"
if [ ! -d .venv ]; then
  python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt
fi
.venv/bin/python agent_harness.py &
BRIDGE=$!
sleep 2
godot --path .
kill $BRIDGE 2>/dev/null

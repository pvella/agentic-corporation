#!/bin/zsh
# Exposes the Agent Office MCP connector (127.0.0.1:8766) on the internet with
# Tailscale Funnel, so cloud-hosted bots can reach it at
#   https://<this-mac>.<tailnet>.ts.net/mcp
#
#   tools/funnel-mac.sh on       start (persists across reboots until turned off)
#   tools/funnel-mac.sh off      stop
#   tools/funnel-mac.sh status   show what is exposed
#   tools/funnel-mac.sh url      print the connector URL
#
# One-time setup: Tailscale installed and logged in, HTTPS certificates and
# Funnel enabled for this device in the tailnet admin console (the first
# `on` prints a link if Funnel is not allowed yet).
set -e
PORT=${OFFICE_MCP_PORT:-8766}
TS=${TAILSCALE:-$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)}

url() {
  local host
  host=$("$TS" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
  echo "https://$host/mcp"
}

case "${1:-status}" in
  on)
    "$TS" funnel --bg "$PORT"
    echo "MCP connector URL: $(url)"
    echo "Header: Authorization: Bearer <token from .office_token or \$OFFICE_MCP_TOKEN>"
    ;;
  off)
    "$TS" funnel --https=443 off
    ;;
  status)
    "$TS" funnel status
    ;;
  url)
    url
    ;;
  *)
    echo "usage: $0 on|off|status|url" >&2
    exit 2
    ;;
esac

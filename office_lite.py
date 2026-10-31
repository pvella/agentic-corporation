"""Phone-friendly /lite ops view served by the harness (inspired by AgentSystemLabs/agent-office MIT).

Reimplemented for Agentic Corporation — credit AgentSystemLabs in README/CREDITS.
Bind with --lite-port (default 8787). Reachable over Tailscale when host is 0.0.0.0
or via Tailscale Serve/Funnel to localhost.
"""
from __future__ import annotations

import html
import json
import logging
from typing import Any

log = logging.getLogger("office_lite")

HTML_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Agent Office · lite</title>
<style>
  :root { --bg:#f6f1e8; --card:#fff; --ink:#1a1a1a; --muted:#666; --need:#c62828; --ok:#2e7d32; --acc:#1565c0; }
  * { box-sizing: border-box; }
  body { margin:0; font:16px/1.4 system-ui,sans-serif; background:var(--bg); color:var(--ink); }
  header { display:flex; align-items:center; gap:.75rem; padding:.75rem 1rem; background:#fff8e1; border-bottom:3px solid #111; position:sticky; top:0; }
  header h1 { font-size:1.1rem; margin:0; flex:1; }
  .bell { background:var(--need); color:#fff; border-radius:999px; padding:.15rem .55rem; font-weight:700; display:none; }
  .bell.on { display:inline-block; }
  main { padding:1rem; max-width:720px; margin:0 auto; }
  .card { background:var(--card); border:2px solid #111; border-radius:10px; padding:.75rem 1rem; margin-bottom:.75rem; }
  .row { display:flex; gap:.5rem; align-items:center; flex-wrap:wrap; }
  .name { font-weight:700; }
  .role { color:var(--muted); font-size:.85rem; }
  .st { font-size:.8rem; padding:.1rem .45rem; border-radius:6px; background:#eee; }
  .st.need { background:var(--need); color:#fff; }
  .st.work { background:#1565c0; color:#fff; }
  .st.think { background:#6a1b9a; color:#fff; }
  form { display:flex; gap:.4rem; margin-top:.5rem; }
  input,button,select { font:inherit; padding:.4rem .55rem; border:2px solid #111; border-radius:8px; }
  button { background:#111; color:#fff; cursor:pointer; }
  .muted { color:var(--muted); font-size:.85rem; }
  footer { text-align:center; padding:1rem; color:var(--muted); font-size:.8rem; }
</style>
</head>
<body>
<header>
  <h1>Agent Office · lite</h1>
  <span id="bell" class="bell">0</span>
  <button type="button" onclick="refresh()">↻</button>
</header>
<main>
  <div class="card">
    <div class="muted">Workers · needs-you first · reply below</div>
    <div id="workers"></div>
  </div>
  <div class="card">
    <div class="muted">Tasks / PRs (from notices)</div>
    <div id="prs" class="muted">Loading…</div>
  </div>
  <div class="card">
    <form id="reply" onsubmit="return sendReply(event)">
      <select id="agent"></select>
      <input id="text" placeholder="Reply / dispatch…" style="flex:1" required/>
      <button type="submit">Send</button>
    </form>
  </div>
</main>
<footer>Ops view · same harness as Godot · inspired by AgentSystemLabs/agent-office (MIT)</footer>
<script>
async function refresh(){
  const r = await fetch('/lite/api/state');
  const j = await r.json();
  const w = document.getElementById('workers');
  const sel = document.getElementById('agent');
  const bell = document.getElementById('bell');
  w.innerHTML = '';
  sel.innerHTML = '';
  let needs = 0;
  (j.agents||[]).forEach(a=>{
    if(a.needs_you) needs++;
    const d=document.createElement('div');
    d.className='card';
    d.style.margin='.4rem 0';
    const st = a.needs_you ? 'need' : (a.state||'').toLowerCase().includes('think') ? 'think' : (a.busy?'work':'');
    d.innerHTML = `<div class="row"><span class="name">${esc(a.name)}</span>
      <span class="role">${esc(a.role||a.agent_id)}</span>
      <span class="st ${st}">${esc(a.needs_you?'NEEDS YOU':a.state)}</span></div>
      <div class="muted">${esc(a.room||'')} · ${esc(a.desk||'')}${a.text? ' · '+esc(a.text):''}</div>`;
    w.appendChild(d);
    const o=document.createElement('option');
    o.value=a.agent_id; o.textContent=a.name+(a.needs_you?' ⚠':'');
    sel.appendChild(o);
  });
  bell.textContent = String(needs);
  bell.className = 'bell'+(needs?' on':'');
  const prs = document.getElementById('prs');
  if((j.prs||[]).length){
    prs.innerHTML = (j.prs||[]).map(p=>`<div>• ${esc(p)}</div>`).join('');
  } else {
    prs.textContent = 'No open PR links reported yet.';
  }
}
function esc(s){ const d=document.createElement('div'); d.textContent=s||''; return d.innerHTML; }
async function sendReply(ev){
  ev.preventDefault();
  const agent=document.getElementById('agent').value;
  const text=document.getElementById('text').value.trim();
  if(!agent||!text) return false;
  await fetch('/lite/api/reply',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({agent_id:agent,text})});
  document.getElementById('text').value='';
  refresh();
  return false;
}
refresh();
setInterval(refresh, 4000);
</script>
</body>
</html>
"""


class LiteServer:
    """Minimal aiohttp app mounted beside MCP."""

    def __init__(self, hub: Any) -> None:
        self.hub = hub
        self.runner: Any = None
        self.site: Any = None
        self.port = 0
        self._needs: set[str] = set()
        self._prs: list[str] = []

    def mark_needs(self, agent_id: str, on: bool = True) -> None:
        if on:
            self._needs.add(agent_id)
        else:
            self._needs.discard(agent_id)

    def note_pr(self, line: str) -> None:
        self._prs.insert(0, line)
        self._prs = self._prs[:40]

    def state(self) -> dict[str, Any]:
        agents = []
        for a in self.hub.agents.values():
            agents.append({
                "agent_id": a.agent_id,
                "name": a.name,
                "role": a.role,
                "room": a.room,
                "desk": a.desk,
                "state": a.state,
                "text": (a.text or "")[:120],
                "busy": a.lock.locked(),
                "needs_you": a.agent_id in self._needs or str(a.state).upper() in ("AWAITING_INPUT", "NEEDS_YOU"),
            })
        agents.sort(key=lambda x: (not x["needs_you"], x["name"].lower()))
        return {"agents": agents, "prs": list(self._prs), "needs_count": sum(1 for a in agents if a["needs_you"])}

    async def start(self, host: str, port: int) -> None:
        from aiohttp import web

        app = web.Application()
        app.router.add_get("/lite", self._page)
        app.router.add_get("/lite/", self._page)
        app.router.add_get("/lite/api/state", self._api_state)
        app.router.add_post("/lite/api/reply", self._api_reply)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        self.site = web.TCPSite(self.runner, host, port)
        await self.site.start()
        self.port = port
        log.info("lite ops view on http://%s:%d/lite", host, port)

    async def stop(self) -> None:
        if self.runner is not None:
            await self.runner.cleanup()

    async def _page(self, _request: Any) -> Any:
        from aiohttp import web
        return web.Response(text=HTML_PAGE, content_type="text/html")

    async def _api_state(self, _request: Any) -> Any:
        from aiohttp import web
        return web.json_response(self.state())

    async def _api_reply(self, request: Any) -> Any:
        from aiohttp import web
        try:
            body = await request.json()
        except Exception:
            return web.json_response({"ok": False, "error": "bad json"}, status=400)
        agent_id = str(body.get("agent_id", "")).strip()
        text = str(body.get("text", "")).strip()
        if agent_id not in self.hub.agents or not text:
            return web.json_response({"ok": False, "error": "agent_id and text required"}, status=400)
        agent = self.hub.agents[agent_id]
        # Clear needs-you when human replies via lite
        self.mark_needs(agent_id, False)
        if getattr(self.hub, "inbox_for", None) and self.hub.inbox_for(agent):
            self.hub.queue_message(agent, f"[lite] {text}")
        else:
            await agent.queue.put(f"[lite] {text}")
        self.hub.emit({"type": "NEEDS_YOU_CLEAR", "agent_id": agent_id})
        return web.json_response({"ok": True})

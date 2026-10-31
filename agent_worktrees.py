"""Per-agent git worktrees + safe PR open via gh.

Inspired by AgentSystemLabs/agent-office worktrees (MIT) — reimplemented here.
Never deletes unpushed work: cleanup only removes worktrees that are clean
AND whose branch is fully pushed (or already merged).
"""
from __future__ import annotations

import logging
import os
import subprocess
from pathlib import Path
from typing import Any

log = logging.getLogger("agent_worktrees")

ROOT_NAME = ".agent_worktrees"


def _run(argv: list[str], cwd: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, cwd=cwd, text=True, capture_output=True, check=False)


class WorktreeManager:
    def __init__(self, project: str) -> None:
        self.project = Path(project).resolve()
        self.root = self.project / ROOT_NAME
        self.root.mkdir(exist_ok=True)
        self._map: dict[str, Path] = {}

    def ensure(self, agent_id: str, branch: str | None = None) -> Path:
        """Create or reuse a worktree for agent_id. Returns the path."""
        safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in agent_id)[:64]
        path = self.root / safe
        if agent_id in self._map and self._map[agent_id].is_dir():
            return self._map[agent_id]
        if path.is_dir():
            self._map[agent_id] = path
            return path
        br = branch or f"agent/{safe}"
        # Prefer creating from HEAD
        r = _run(["git", "worktree", "add", "-b", br, str(path)], cwd=str(self.project))
        if r.returncode != 0:
            # Branch may exist — try without -b
            r2 = _run(["git", "worktree", "add", str(path), br], cwd=str(self.project))
            if r2.returncode != 0:
                log.warning("worktree add failed for %s: %s %s", agent_id, r.stderr, r2.stderr)
                # Fallback: plain directory (not a worktree) so cwd still isolates
                path.mkdir(parents=True, exist_ok=True)
        self._map[agent_id] = path
        return path

    def open_pr(self, agent_id: str, title: str, body: str = "") -> str:
        path = self._map.get(agent_id) or self.ensure(agent_id)
        # Push branch
        br = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=str(path))
        branch = (br.stdout or "").strip() or f"agent/{agent_id}"
        push = _run(["git", "push", "-u", "origin", branch], cwd=str(path))
        if push.returncode != 0:
            return f"push failed: {push.stderr.strip()}"
        pr = _run(["gh", "pr", "create", "--title", title, "--body", body or f"Agent {agent_id} work"], cwd=str(path))
        if pr.returncode != 0:
            return f"gh pr failed: {pr.stderr.strip()}"
        return (pr.stdout or "").strip()

    def safe_cleanup(self, agent_id: str) -> str:
        """Remove worktree only if clean and pushed. Never deletes unpushed commits."""
        path = self._map.get(agent_id)
        if path is None or not path.is_dir():
            return "no worktree"
        st = _run(["git", "status", "--porcelain"], cwd=str(path))
        if st.stdout.strip():
            return "refused: uncommitted changes present"
        # Unpushed commits?
        unpushed = _run(["git", "log", "@{u}..HEAD", "--oneline"], cwd=str(path))
        if unpushed.returncode == 0 and unpushed.stdout.strip():
            return "refused: unpushed commits present"
        if unpushed.returncode != 0:
            # No upstream — refuse
            return "refused: no upstream (would lose unpushed work)"
        r = _run(["git", "worktree", "remove", "--force", str(path)], cwd=str(self.project))
        self._map.pop(agent_id, None)
        if r.returncode != 0:
            return f"remove failed: {r.stderr.strip()}"
        return "removed"

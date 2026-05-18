"""SubagentStop hook — verify developer/tester worktree is clean when the
agent reports `Outcome: SUCCESS`.

Reads the hook payload file path from argv[1].

Background: the orchestrator historically committed on behalf of agents that
reported SUCCESS but left uncommitted changes in their worktree. That violates
CC-02.1 (role boundary: orchestrator does not write code) and corrupts metrics
(the agent's commit hash in AGENT STATUS doesn't match what's actually on the
branch). This hook catches the gap structurally instead of relying on agent
self-policing.

Scope: only developer + tester (worktree-aware roles, must commit before exit).
    - Planner: writes plan/tracker via Write tool, not a worktree → skipped.
    - Reviewer: read-only (CC-02.7), cannot have dirty worktree → skipped.

Fail policy: fail-CLOSED when:
    - The AGENT STATUS block parses cleanly
    - Agent ∈ {developer, tester}
    - Outcome value is exactly SUCCESS (PARTIAL/BLOCKED/FAILED have their own
      reason fields; a dirty worktree alongside PARTIAL is the expected
      WIP-checkpoint path — see soft-cap termination rule)
    - A valid git-repo path can be resolved from Worktree or Repo path
    - `git -C <path> status --porcelain` returns non-empty output

Fail-OPEN when:
    - AGENT STATUS block missing / unparseable (`_agent_status_check.py`
      handles that path; this hook stays silent to avoid duplicate errors)
    - Agent name not in scope
    - Path cannot be resolved or doesn't exist
    - Worktree value is `not used (direct branch)` AND Repo path is also
      unresolvable
    - Any subprocess error

Exit codes:
    0   passing / out-of-scope / unresolvable
    2   FAIL-CLOSED: dirty worktree reported alongside Outcome: SUCCESS
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

from _block_parsing import extract_field_value, extract_status_block  # noqa: E402
from _subagent_utils import normalize_agent_type  # noqa: E402


_IN_SCOPE_AGENTS = {"developer", "tester"}


def _agent_from_block(block: str) -> Optional[str]:
    """Normalise the `Agent:` field value to a canonical short name.

    Mirrors `_agent_status_check.py._normalise_agent_name` — strips the
    `ai-sdlc-` plugin prefix so the result matches `_IN_SCOPE_AGENTS`.
    """
    raw = extract_field_value(block, "Agent")
    if raw is None:
        return None
    cleaned = raw.strip().replace("ai-sdlc-", "", 1).strip().lower()
    return cleaned or None
_DIRECT_BRANCH_MARKERS = (
    "not used (direct branch)",
    "n/a",
    "none",
    "",
)


def _extract_response(payload: dict) -> str:
    """Same extraction strategy as `_agent_status_check.py` — read the
    response text from whichever payload key is populated."""
    for k in ("response", "agent_response", "final_response", "text", "output", "result"):
        v = payload.get(k)
        if isinstance(v, str) and v.strip():
            return v
    msgs = payload.get("messages") or payload.get("transcript") or []
    if isinstance(msgs, list) and msgs:
        last = msgs[-1]
        if isinstance(last, dict):
            content = last.get("content")
            if isinstance(content, str):
                return content
            if isinstance(content, list):
                parts = []
                for block in content:
                    if isinstance(block, dict) and isinstance(block.get("text"), str):
                        parts.append(block["text"])
                if parts:
                    return "\n".join(parts)
    return ""


def _resolve_worktree_path(block: str) -> Optional[str]:
    """Resolve the agent's working-tree directory from its AGENT STATUS block.

    Preference order: `Worktree:` (when not a direct-branch marker) → `Repo
    path:`. Returns None when neither yields a usable path.
    """
    wt = extract_field_value(block, "Worktree")
    if wt is not None:
        wt_clean = wt.strip().strip("`").strip()
        if wt_clean.lower() not in _DIRECT_BRANCH_MARKERS:
            return wt_clean
    repo = extract_field_value(block, "Repo path")
    if repo is not None:
        repo_clean = repo.strip().strip("`").strip()
        if repo_clean:
            return repo_clean
    return None


def _git_status_porcelain(path: str) -> Optional[str]:
    """Return `git -C <path> status --porcelain` output, or None when the
    directory isn't a git repo / the command failed."""
    if not os.path.isdir(path):
        return None
    try:
        result = subprocess.run(
            ["git", "-C", path, "status", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, json.JSONDecodeError):
        return 0

    response = _extract_response(payload)
    if not response:
        return 0

    block = extract_status_block(response)
    if not block:
        return 0

    agent = _agent_from_block(block) or normalize_agent_type(payload)
    if agent not in _IN_SCOPE_AGENTS:
        return 0

    outcome = (extract_field_value(block, "Outcome") or "").strip()
    if outcome != "SUCCESS":
        return 0

    path = _resolve_worktree_path(block)
    if not path:
        return 0

    porcelain = _git_status_porcelain(path)
    if porcelain is None:
        return 0
    if not porcelain.strip():
        return 0

    files = [line for line in porcelain.splitlines() if line.strip()]
    file_count = len(files)
    preview = files[:10]
    overflow = file_count - len(preview)

    print(
        f"❌ {agent} reported Outcome: SUCCESS but the worktree is dirty",
        file=sys.stderr,
    )
    print(f"   path: {path}", file=sys.stderr)
    print(
        f"   {file_count} uncommitted change(s) detected by "
        f"`git -C {path} status --porcelain`:",
        file=sys.stderr,
    )
    for line in preview:
        print(f"     {line}", file=sys.stderr)
    if overflow > 0:
        print(f"     ... and {overflow} more", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "Recovery: per CC-02.1 the orchestrator must not commit on behalf of "
        "the agent. The agent must:",
        file=sys.stderr,
    )
    print(
        "  1. Re-emit AGENT STATUS as `Outcome: PARTIAL` with `Blockers: "
        "uncommitted changes` (matches the soft-cap WIP-checkpoint contract), "
        "OR",
        file=sys.stderr,
    )
    print(
        "  2. Commit the pending changes (per the agent's index.md commit "
        "step) and re-emit AGENT STATUS with the new commit hash.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())

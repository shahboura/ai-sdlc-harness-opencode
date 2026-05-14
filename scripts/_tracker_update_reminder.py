#!/usr/bin/env python3
"""PostToolUse on Agent — advisory hook that reminds the orchestrator to
sync the tracker after every subagent verdict.

Reads the hook payload file path from argv[1]. Outputs JSON with
`hookSpecificOutput.additionalContext` when a reminder is needed; otherwise
prints nothing and exits 0. Never blocks (advisory).

Fixes vs. the previous shell implementation:
- One Python invocation reads both `tool_response` and `tool_input.prompt`
  (the old PROMPT=… echo … | python pipeline only set PROMPT for `echo`).
- `tool_response` accepts both string and list-of-content-blocks shapes.
- The AGENT STATUS block extends to the next H1/H2 or EOF instead of being
  truncated at the first blank line.
- Tracker selection: match the story ID from the orchestrator prompt against
  tracker filenames; fall back to most-recent mtime only when no match.
- Workspace root resolved by walking up from cwd to find
  `.claude/context/provider-config.md` (handles orchestrator cd'ing into
  subdirs).
"""
from __future__ import annotations

import json
import os
import re
import sys
from typing import Any


_LABEL = {
    "pending": "⏳ Pending",
    "in_progress": "🔧 In Progress",
    "in_review": "🔄 In Review",
    "done": "✅ Done",
}


def _join_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                parts.append(item.get("text", ""))
        return "\n".join(parts)
    return ""


def _workspace_root_from_cwd() -> str | None:
    d = os.getcwd()
    while d and d != "/":
        if os.path.isfile(os.path.join(d, ".claude/context/provider-config.md")):
            return d
        d = os.path.dirname(d)
    return None


def _extract_status_block(text: str) -> str | None:
    """Find `AGENT STATUS` and return the block extending to the next H1/H2
    heading or EOF. The previous implementation stopped at `\\n\\n` and lost
    multi-paragraph fields.
    """
    m = re.search(r"(?:📋\s*)?AGENT STATUS\b[^\n]*\n", text)
    if not m:
        return None
    start = m.start()
    rest = text[m.end():]
    end_m = re.search(r"\n#{1,2}\s", rest)
    if end_m:
        return text[start : m.end() + end_m.start()]
    return text[start:]


def _find_field(block: str, name: str) -> str:
    pat = re.compile(rf"^\s*{re.escape(name)}\s*:\s*(.+?)\s*$", re.MULTILINE)
    m = pat.search(block)
    return m.group(1) if m else ""


def _find_task_id(block: str, prompt: str) -> str:
    for text in (block, prompt or ""):
        m = re.search(r"(?:Task|task)\s+(T-TEST[^\s,|]*|T[\w.\-]+)", text)
        if m:
            return m.group(1)
        m = re.search(r"\b(T-TEST[^\s,|]*|T\d+)\b", text)
        if m:
            return m.group(1)
    return ""


def _normalise_agent(name: str) -> str:
    n = (name or "").strip().lower()
    for sep in (":", "/"):
        if sep in n:
            n = n.rsplit(sep, 1)[-1]
    return n


def _determine_agent(subagent_type: str, response: str) -> str:
    n = _normalise_agent(subagent_type)
    if n in {"developer", "reviewer", "tester", "planner"}:
        return n
    lowered = response.lower()
    for kw, t in (
        ("self-review", "developer"),
        ("worktree", "developer"),
        ("spec compliance", "reviewer"),
        ("verdict", "reviewer"),
        ("coverage", "tester"),
        ("tests written", "tester"),
    ):
        if kw in lowered:
            return t
    return ""


def _parse_task_status(content: str, task_id: str) -> str | None:
    pat = re.compile(
        rf"^\|\s*{re.escape(task_id)}\s*\|.*$",
        re.MULTILINE,
    )
    m = pat.search(content)
    if not m:
        return None
    cells = [c.strip() for c in m.group(0).split("|")[1:-1]]
    for c in cells[1:]:  # skip the ID cell
        if "⏳" in c:
            return "pending"
        if "🔧" in c:
            return "in_progress"
        if "🔄" in c:
            return "in_review"
        if "✅" in c:
            return "done"
    return None


def _find_tracker(workspace_root: str | None, story_hint: str) -> str | None:
    base = os.path.join(workspace_root or "", "ai", "tasks") if workspace_root else "ai/tasks"
    if not os.path.isdir(base):
        return None
    md_files = [f for f in os.listdir(base) if f.endswith(".md")]
    if not md_files:
        return None
    # Prefer filename match
    if story_hint:
        for f in sorted(md_files, reverse=True):
            if story_hint in f:
                return os.path.join(base, f)
    # Fallback: most recent mtime
    md_files.sort(
        key=lambda f: os.path.getmtime(os.path.join(base, f)), reverse=True
    )
    return os.path.join(base, md_files[0])


def _expected_status(agent: str, outcome: str, verdict: str) -> str | None:
    if agent in {"developer", "tester"}:
        if outcome in {"SUCCESS", "DONE_WITH_CONCERNS"}:
            return "in_review"
        return None
    if agent == "reviewer":
        if verdict == "APPROVED":
            return "done"
        if verdict == "CHANGES_REQUESTED":
            return "in_progress"
    return None


def _build_reminder(
    agent: str,
    task_id: str,
    tracker_path: str,
    current: str,
    expected: str,
) -> str:
    msg = (
        f"TRACKER UPDATE NEEDED: The {agent} just completed for {task_id} "
        f'but the tracker at {tracker_path} still shows "{_LABEL[current]}". '
        f'Update {task_id} to "{_LABEL[expected]}"'
    )
    if expected == "in_review":
        msg += (
            ".\n\nUse: Edit the tracker row for "
            f"{task_id}, changing the Status column to 🔄 In Review."
        )
    elif expected == "in_progress" and agent == "reviewer":
        msg += (
            " (changes requested). Increment Review Rounds by 1 and "
            "record the reviewer's comments in the Notes column."
        )
    elif expected == "done":
        msg += (
            ".\n\nAlso update the Task Metrics table for "
            f"{task_id}:\n"
            "- Set Completed to the output of: date -u +\"%Y-%m-%d %H:%M UTC\"\n"
            "- Increment Review Rounds by 1\n\n"
            "For reviewer approved: also record the commit hash and set "
            "Reviewer Verdict to ✅ Approved."
        )
    return msg


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, json.JSONDecodeError):
        return 0

    if payload.get("tool_name") != "Agent":
        return 0

    response = _join_text(payload.get("tool_response", ""))
    if not response:
        return 0

    tool_input = payload.get("tool_input") or {}
    subagent_type = tool_input.get("subagent_type") or payload.get("agent_type", "")
    prompt = tool_input.get("prompt", "") or ""

    agent = _determine_agent(subagent_type, response)
    if not agent:
        return 0

    block = _extract_status_block(response)
    if not block:
        return 0

    outcome = _find_field(block, "Outcome")
    verdict = _find_field(block, "Verdict")
    expected = _expected_status(agent, outcome, verdict)
    if not expected:
        return 0

    workspace = _workspace_root_from_cwd()
    # Pull a story hint from the prompt (ADO numeric / Jira PROJ-123 / slug)
    story_hint = ""
    m = re.search(r"#?(\d{2,})\b|\b([A-Z][A-Z0-9]+-\d+)\b", prompt or "")
    if m:
        story_hint = m.group(1) or m.group(2) or ""

    tracker = _find_tracker(workspace, story_hint)
    if not tracker:
        return 0

    try:
        with open(tracker, "r", encoding="utf-8") as f:
            tracker_content = f.read()
    except OSError:
        return 0

    task_id = _find_task_id(block, prompt)
    if not task_id:
        if agent == "reviewer":
            m = re.search(
                r"^\|\s*(T(?:-TEST)?[\w.\-]*)\s*\|.*🔄",
                tracker_content,
                re.MULTILINE,
            )
            task_id = m.group(1) if m else ""
        elif agent == "tester":
            m = re.search(
                r"^\|\s*(T-TEST[\w.\-]*)\s*\|",
                tracker_content,
                re.MULTILINE,
            )
            task_id = m.group(1) if m else ""
    if not task_id:
        return 0

    current = _parse_task_status(tracker_content, task_id)
    if current is None or current == expected:
        return 0

    reminder = _build_reminder(agent, task_id, tracker, current, expected)
    print(json.dumps({"hookSpecificOutput": {"additionalContext": reminder}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())

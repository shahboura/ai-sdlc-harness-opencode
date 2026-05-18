#!/usr/bin/env python3
"""Tracker transition guard.

Validates that every status change in a tracker edit follows the legal
transition graph:

    (new row)      → ⏳ Pending        (added to an existing tracker)
    ⏳ Pending     → 🔧 In Progress
    🔧 In Progress → 🔄 In Review
    🔄 In Review   → ✅ Done           (reviewer approved)
    🔄 In Review   → 🔧 In Progress    (changes requested)
    ✅ Done        → 🔧 In Progress    (rework)
    ✅ Done        → 📦 Archived       (P8 reconcile — M-07)
    📦 Archived    → 🔧 In Progress    (hotfix clone — M-19; operates on a clone, original row preserved)

Covers `Write`, `Edit`, and `MultiEdit` — applies the edit in-memory to the
on-disk file content, then diffs task-row statuses by task ID and validates
every transition that actually changed. Same-status edits and metadata-only
column changes (Notes, Commit hashes, Reviewer Verdict, timestamps) pass
through silently.

New rows added to an existing tracker must start in ⏳ Pending. Rows that
appear in non-pending status without going through the proper lifecycle are
rejected (closes the "create a row already marked Done" loophole). When the
tracker file does not yet exist on disk (initial Write), there is no
pre-state to compare against and the write passes through.

Reads the hook payload file path from argv[1].

Exit 0 = allow, Exit 2 = block.

Changed by: dev-workflow-plan.md [M-07] [IMPL-07-04]
Reason: Add `Archived` as a terminal state reachable from `Done` (P8 reconcile);
        per `agents/shared/tracker-transition-rules.md`, the FSM is authoritative.
CC conventions applied: CC-03.3, CC-04.5 (defers FSM to shared transition-rules).
"""
from __future__ import annotations

import json
import os
import re
import sys


_EMOJI_TO_KEY = {
    "⏳": "pending",
    "🔧": "in_progress",
    "🔄": "in_review",
    "✅": "done",
    "📦": "archived",
}

_LEGAL: dict[str, set[str]] = {
    "pending": {"in_progress"},
    "in_progress": {"in_review"},
    "in_review": {"done", "in_progress"},
    "done": {"in_progress", "archived"},
    "archived": {"in_progress"},  # M-19 hotfix clone — operates on a clone, original row policy-bounded
}

_LABEL = {
    "pending": "⏳ Pending",
    "in_progress": "🔧 In Progress",
    "in_review": "🔄 In Review",
    "done": "✅ Done",
    "archived": "📦 Archived",
    "NONE": "(new row)",
}

# Matches BOTH the legacy layout (ai/tasks/<X>.md) AND the new per-workflow
# layout (ai/<YYYY-MM-DD>-<work-item-id>/tracker.md or tracker.archived.md or
# tracker.aborted.md) per M-14 IMPL-14-05.
_TRACKER_PATH_RE = re.compile(
    r"(^|/)ai/(tasks/|\d{4}-\d{2}-\d{2}-[\w.-]+/tracker(\.archived|\.aborted)?\.md$)"
)
# Task IDs always start with T and contain word chars / dot / hyphen. This
# pattern also matches table-header words like "Task" or "Type"; those cells
# never carry a status emoji, so `_parse_task_statuses` simply finds no
# status for them and they're silently ignored.
_TASK_ID_RE = re.compile(r"^T[\w.-]*$")


def _is_tracker_file(path: str) -> bool:
    return bool(_TRACKER_PATH_RE.search(path))


def _parse_task_statuses(content: str) -> dict[str, str]:
    """Return {task_id: status_key} for every recognisable table row.

    A row qualifies when it starts with `|`, has at least three cells, and
    contains a cell matching `^T[\\w.-]*$`. The status is taken from the
    first emoji found in subsequent cells.
    """
    statuses: dict[str, str] = {}
    for line in content.splitlines():
        if not line.lstrip().startswith("|"):
            continue
        # Strip leading/trailing | then split. A trailing | yields an empty
        # final cell; drop it.
        parts = [c.strip() for c in line.split("|")]
        # Drop the leading empty cell (before the first |).
        if parts and parts[0] == "":
            parts = parts[1:]
        # Drop the trailing empty cell (after the last |).
        if parts and parts[-1] == "":
            parts = parts[:-1]
        cells = parts
        if len(cells) < 3:
            continue
        task_id_idx = None
        for i, c in enumerate(cells):
            if _TASK_ID_RE.match(c):
                task_id_idx = i
                break
        if task_id_idx is None:
            continue
        task_id = cells[task_id_idx]
        for c in cells[task_id_idx + 1 :]:
            for emoji, key in _EMOJI_TO_KEY.items():
                if emoji in c:
                    statuses[task_id] = key
                    break
            if task_id in statuses:
                break
    return statuses


def _apply_edit(content: str, old: str, new: str) -> str | None:
    if not old:
        return None
    if old not in content:
        return None
    return content.replace(old, new, 1)


def _apply_tool(content: str, tool_name: str, tool_input: dict) -> str | None:
    if tool_name == "Write":
        # Write replaces the whole file content
        return tool_input.get("content", "")
    if tool_name == "Edit":
        return _apply_edit(
            content,
            tool_input.get("old_string", ""),
            tool_input.get("new_string", ""),
        )
    if tool_name == "MultiEdit":
        cur = content
        for e in tool_input.get("edits", []) or []:
            cur = _apply_edit(cur, e.get("old_string", ""), e.get("new_string", ""))
            if cur is None:
                return None
        return cur
    return None


def _violations(before: dict[str, str], after: dict[str, str]) -> list[tuple[str, str, str]]:
    out: list[tuple[str, str, str]] = []
    for task_id, new_status in after.items():
        old_status = before.get(task_id)
        if old_status is None:
            # New row added to an existing tracker. The only legal initial
            # status is ⏳ Pending — every other state implies workflow
            # progress that must go through the proper transitions.
            if new_status != "pending":
                out.append((task_id, "NONE", new_status))
            continue
        if old_status == new_status:
            continue
        if new_status not in _LEGAL.get(old_status, set()):
            out.append((task_id, old_status, new_status))
    return out


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, json.JSONDecodeError):
        return 0

    tool_name = payload.get("tool_name", "")
    if tool_name not in {"Write", "Edit", "MultiEdit"}:
        return 0

    tool_input = payload.get("tool_input") or {}
    file_path = tool_input.get("file_path", "")
    if not file_path or not _is_tracker_file(file_path):
        return 0

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            current = f.read()
    except OSError:
        # File doesn't exist yet — a Write creating a new tracker has nothing
        # to transition from. Allow.
        return 0

    post = _apply_tool(current, tool_name, tool_input)
    if post is None:
        # Edit can't be applied to the current content — the tool itself
        # will fail. Don't pile on a transition error.
        return 0

    before = _parse_task_statuses(current)
    after = _parse_task_statuses(post)
    violations = _violations(before, after)
    if not violations:
        return 0

    print("tracker-transition-guard: illegal status transition(s)", file=sys.stderr)
    for tid, old, new in violations:
        print(f"  - {tid}: {_LABEL[old]} → {_LABEL[new]}", file=sys.stderr)
    print("", file=sys.stderr)
    print("Legal transitions:", file=sys.stderr)
    print("  (new row)      → ⏳ Pending        (added to an existing tracker)", file=sys.stderr)
    print("  ⏳ Pending     → 🔧 In Progress", file=sys.stderr)
    print("  🔧 In Progress → 🔄 In Review", file=sys.stderr)
    print("  🔄 In Review   → ✅ Done           (reviewer approved)", file=sys.stderr)
    print("  🔄 In Review   → 🔧 In Progress    (changes requested)", file=sys.stderr)
    print("  ✅ Done        → 🔧 In Progress    (rework)", file=sys.stderr)
    print("  ✅ Done        → 📦 Archived       (P8 reconcile — M-07)", file=sys.stderr)
    print("  📦 Archived    → 🔧 In Progress    (hotfix clone — M-19)", file=sys.stderr)
    print(f"File: {file_path}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

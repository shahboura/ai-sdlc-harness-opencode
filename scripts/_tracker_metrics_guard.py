#!/usr/bin/env python3
"""Tracker metrics guard — advisory + Gate-prompted stamp emitter.

Hook payload (argv[1]) drives the advisory layer: warns when timestamp values
written to a tracker file do not use the full `YYYY-MM-DD HH:MM UTC` format.

Also exposes `stamp_gate_prompted(gate_id, tracker_path, now_utc)` — a
non-hook helper called by the orchestrator at every gate prompt to append a
single `Gate prompted <ts> — <gate-id>` line to the tracker's metrics block.
Per RAG-28 / TEST-177 the stamp is idempotency-aware: re-stamping the same
gate without an intervening progression is a no-op.

Valid formats (advisory layer):
    2026-04-05 14:30 UTC     full datetime, required
    --                       placeholder, allowed
    local-test               special CI value, allowed

Invalid formats (warned, never blocked):
    2026-04-05               date only — time missing
    2026-04-05T14:30         ISO 8601 T separator instead of space
    2026-04-05 14:30         missing UTC suffix

Fail policy: always exit 0 (advisory only). Print warnings to stdout so the
edit proceeds while the user still sees the hint.

Changed by: dev-workflow-plan.md [M-01] [IMPL-01-16]
Reason: Add `stamp_gate_prompted` per RAG-28 / TEST-177.
CC conventions applied: CC-05.1, CC-05.3, CC-09.
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


# Matches BOTH legacy `ai/tasks/<X>.md` AND new per-workflow `ai/<YYYY-MM-DD>-<id>/tracker*.md`
# (M-14 IMPL-14-05 — additive backward compatibility during the migration window).
_TRACKER_PATH_RE = re.compile(
    r"(^|/)ai/(tasks/|\d{4}-\d{2}-\d{2}-[\w.-]+/tracker(\.archived|\.aborted)?\.md$)"
)
# A date-shaped token NOT immediately followed by ' HH:MM UTC'.
#
#   2026-04-05 14:30 UTC   → negative lookahead blocks → no match (valid)
#   2026-04-05             → lookahead fails → matches (incomplete)
#   2026-04-05 14:30       → lookahead fails (no UTC) → matches (missing suffix)
#   2026-04-05T14:30       → T is not \s → lookahead fails → matches (wrong sep)
_INVALID_TS_RE = re.compile(r"\d{4}-\d{2}-\d{2}(?!\s+\d{2}:\d{2}\s+UTC)")


def _is_tracker_file(path: str) -> bool:
    return bool(_TRACKER_PATH_RE.search(path))


# ---------------------------------------------------------------------------
# IMPL-01-16 — stamp_gate_prompted (RAG-28 infrastructure portion / TEST-177)
# ---------------------------------------------------------------------------

# Canonical line format emitted to the tracker's Metrics block.
#   Gate prompted 2026-05-17 14:32 UTC — gate-2
_GATE_STAMP_PREFIX = "Gate prompted "

# Per-gate idempotency: re-stamping the same gate without an intervening
# `Plan approved`, `Human approval (impl)`, `PR created`, `PR review response
# completed`, `Merge detected`, `Workflow completed`, or `Recovery started`
# line is a no-op. (Those terminal stamps signal a gate has been crossed;
# another `Gate prompted` afterward refers to a *fresh* gate session.) The
# legacy names (`Approved-Impl`, `PR-Opened`, `Comments resolved`) are also
# accepted so trackers written by pre-2.0 emitters still trigger reset.
_GATE_RESET_STAMPS = (
    "Plan approved ",
    "Human approval (impl) ",
    "PR created ",
    "PR review response completed ",
    "Merge detected ",
    "Workflow completed ",
    "Recovery started ",
    "Workflow aborted ",
    # Legacy stamp names (pre-2.0) — kept for backward read compatibility:
    "Approved-Impl ",
    "PR-Opened ",
    "Comments resolved ",
)


def _last_gate_prompt_for(content: str, gate_id: str) -> int | None:
    """Return the line index of the last `Gate prompted ... — <gate_id>` line
    in `content` (split on \\n), or None when no such line exists.
    """
    target_suffix = f"— {gate_id}"
    last = None
    for i, line in enumerate(content.splitlines()):
        if line.startswith(_GATE_STAMP_PREFIX) and target_suffix in line:
            last = i
    return last


def _has_reset_after(content: str, after_line: int) -> bool:
    """Return True when any `_GATE_RESET_STAMPS` line appears after line index
    `after_line` in `content`.
    """
    for i, line in enumerate(content.splitlines()):
        if i <= after_line:
            continue
        if any(line.startswith(p) for p in _GATE_RESET_STAMPS):
            return True
    return False


def stamp_gate_prompted(gate_id: str, tracker_path: str, now_utc: datetime | str) -> bool:
    """Append `Gate prompted <ts> — <gate-id>` to `tracker_path`.

    Idempotent within a single uninterrupted gate session: re-calling for the
    same `gate_id` without an intervening terminal-stamp (Plan approved,
    Approved-Impl, PR-Opened, Comments resolved, Merge detected, Workflow
    completed, Recovery started, Workflow aborted) is a no-op.

    Args:
        gate_id: short identifier for the gate (e.g. `gate-2`, `gate-3.5`).
        tracker_path: filesystem path to the tracker `.md` file. The file
            must exist; this helper appends to it.
        now_utc: a `datetime` object or a pre-formatted `YYYY-MM-DD HH:MM UTC`
            string. A naive datetime is treated as UTC.

    Returns:
        True when a new stamp was appended; False when the call was an
        idempotent no-op.

    Raises:
        FileNotFoundError when `tracker_path` does not exist.
        ValueError when `gate_id` is empty.
    """
    if not gate_id:
        raise ValueError("stamp_gate_prompted: empty gate_id")

    path = Path(tracker_path)
    if not path.is_file():
        raise FileNotFoundError(f"stamp_gate_prompted: tracker not found at {tracker_path}")

    if isinstance(now_utc, datetime):
        if now_utc.tzinfo is None:
            now_utc = now_utc.replace(tzinfo=timezone.utc)
        ts = now_utc.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    else:
        ts = str(now_utc).strip()

    content = path.read_text(encoding="utf-8")
    last_idx = _last_gate_prompt_for(content, gate_id)
    if last_idx is not None and not _has_reset_after(content, last_idx):
        return False  # idempotent no-op

    line = f"{_GATE_STAMP_PREFIX}{ts} — {gate_id}\n"
    suffix = "" if content.endswith("\n") or content == "" else "\n"
    path.write_text(content + suffix + line, encoding="utf-8")
    return True


def stalled_gates(tracker_path: str, now_utc: datetime, threshold_hours: float) -> list[dict]:
    """Return a list of stalled-gate descriptors from `tracker_path`.

    A gate is **stalled** when its most recent `Gate prompted <ts> — <gate-id>`
    line is older than `threshold_hours` AND no `_GATE_RESET_STAMPS` line
    appears after it (i.e. the gate has not been crossed).

    The default `threshold_hours` per CC-09 is 24h; callers source the value
    from `.claude/context/state.md` `gate_stall_threshold_hours` (workspace
    override).

    Returns:
        List of `{gate_id, prompted_at, age_hours}` dicts, ordered by age
        descending (oldest first).
    """
    path = Path(tracker_path)
    if not path.is_file():
        return []

    content = path.read_text(encoding="utf-8")
    if now_utc.tzinfo is None:
        now_utc = now_utc.replace(tzinfo=timezone.utc)

    # Pull every gate stamp; keep only the latest per gate_id; drop those
    # followed by a reset stamp.
    latest_per_gate: dict[str, tuple[int, datetime]] = {}
    lines = content.splitlines()
    pat = re.compile(
        r"^Gate prompted (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) UTC\s+—\s+(.+?)\s*$"
    )
    for i, line in enumerate(lines):
        m = pat.match(line)
        if not m:
            continue
        try:
            when = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        gate_id = m.group(2)
        latest_per_gate[gate_id] = (i, when)

    out: list[dict] = []
    for gate_id, (line_idx, when) in latest_per_gate.items():
        if _has_reset_after(content, line_idx):
            continue
        age_hours = (now_utc - when).total_seconds() / 3600.0
        if age_hours >= threshold_hours:
            out.append({
                "gate_id": gate_id,
                "prompted_at": when.strftime("%Y-%m-%d %H:%M UTC"),
                "age_hours": round(age_hours, 2),
            })
    out.sort(key=lambda d: d["age_hours"], reverse=True)
    return out


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, json.JSONDecodeError):
        return 0

    if payload.get("tool_name", "") != "Edit":
        return 0

    tool_input = payload.get("tool_input") or {}
    file_path = tool_input.get("file_path", "")
    if not file_path or not _is_tracker_file(file_path):
        return 0

    new_string = tool_input.get("new_string", "")
    if not isinstance(new_string, str) or not new_string:
        return 0

    match = _INVALID_TS_RE.search(new_string)
    if not match:
        return 0

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
    print(f"ADVISORY: Timestamp '{match.group(0)}' in tracker metrics may be incomplete.")
    print("  Required format:  YYYY-MM-DD HH:MM UTC")
    print(f"  Example:          {now} UTC")
    print("  Allowed values:   --  (placeholder)  |  local-test  (CI/test runs)")
    print(f"  File: {file_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

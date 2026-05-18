"""Recovery-state marker writer.

> Owner: cross-cutting (R phase domain)
> Version: 1.0

Created by: dev-workflow-plan.md [M-08] [IMPL-08-07] (+ M-22 [IMPL-22-11] merged
per third-pass patch — `resume_label()` lives here, not in a separate module).

Reason: Orchestrator-side writer for `.claude/context/.recovery-state.md`. The
marker is rotated at three points during normal workflow execution
(independent of crash detection):
    (a) after every successful phase exit (`stamp_phase_exit`)
    (b) on every tracker transition (`stamp_tracker_state`)
    (c) at gate prompt (`stamp_gate_prompt`)

Reader is R Step 4 (`commands/resume.md`) + the `workflow-status` skill. The
hook `stop-failure-recovery.sh` only triggers the resume routing; it never
writes this marker.

CC conventions applied:
    CC-03.3 (isolation — mutates only `.claude/context/.recovery-state.md`)
    CC-03.7 (idempotent — re-write with identical content is a no-op via
             `_atomic_rename.atomic_write`)
    CC-05.4 (phase-boundary enforced by marker stamp)
    CC-01.7 (single-responsibility at the module level — marker-domain only)
    CC-04.2 (`scripts/_<concern>_utils.py` form)
    CC-08.1 (avoid premature function-per-file fragmentation — `resume_label()`
             lives here, not in a separate `_resume_label.py`; both operate on
             the same marker-domain data)

Exports:
    write_recovery_state(workspace_root, *, last_completed_phase=None,
        in_flight_tasks=None, dirty_worktrees=None, timestamp=None) -> bool
    stamp_phase_exit(workspace_root, phase_id, *, timestamp=None) -> bool
    stamp_tracker_state(workspace_root, tracker_path, *, timestamp=None) -> bool
    stamp_gate_prompt(workspace_root, gate_id, *, timestamp=None) -> bool
    read_recovery_state(workspace_root) -> dict | None
    resume_label(workspace_root) -> str         # M-22 IMPL-22-11
"""
from __future__ import annotations

import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Mapping, Optional

from _atomic_rename import atomic_write


_MARKER_RELPATH = ".claude/context/.recovery-state.md"

_REQUIRED_FIELDS = (
    "Last completed phase",
    "In-flight tasks",
    "Dirty worktrees",
    "Timestamp",
)


def _utc_now_str() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def _format_marker(
    *,
    last_completed_phase: str,
    in_flight_tasks: Iterable[str],
    dirty_worktrees: Iterable[str],
    timestamp: str,
) -> str:
    """Render the canonical marker content.

    Field-per-line markdown; comments-only `<!-- ... -->` lines preserved
    on parse. The 4 required fields appear in the order documented in
    `recovery-protocol.md`.
    """
    in_flight_str = ", ".join(in_flight_tasks) if in_flight_tasks else "none"
    dirty_str = ", ".join(dirty_worktrees) if dirty_worktrees else "none"
    return (
        "# Recovery State\n"
        "<!-- Written by scripts/_recovery_state_writer.py per dev-workflow-plan.md M-08 IMPL-08-07. -->\n"
        "<!-- Re-read by `commands/resume.md` Step 4 and the `workflow-status` skill. -->\n"
        "\n"
        f"Last completed phase: {last_completed_phase}\n"
        f"In-flight tasks: {in_flight_str}\n"
        f"Dirty worktrees: {dirty_str}\n"
        f"Timestamp: {timestamp}\n"
    )


def _marker_path(workspace_root: str | os.PathLike) -> Path:
    return Path(workspace_root) / _MARKER_RELPATH


def read_recovery_state(workspace_root: str | os.PathLike) -> Optional[dict]:
    """Return the parsed marker dict, or None when the marker is absent or
    malformed. Field names match the marker's canonical labels.
    """
    path = _marker_path(workspace_root)
    if not path.is_file():
        return None
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    out: dict[str, str] = {}
    for line in text.splitlines():
        m = re.match(r"^([A-Za-z][A-Za-z0-9 -]*?)\s*:\s*(.*?)\s*$", line)
        if not m:
            continue
        field, value = m.group(1), m.group(2)
        if field in _REQUIRED_FIELDS:
            out[field] = value
    # Only return when all 4 required fields are present.
    if not all(f in out for f in _REQUIRED_FIELDS):
        return None
    return out


def write_recovery_state(
    workspace_root: str | os.PathLike,
    *,
    last_completed_phase: Optional[str] = None,
    in_flight_tasks: Optional[Iterable[str]] = None,
    dirty_worktrees: Optional[Iterable[str]] = None,
    timestamp: Optional[str] = None,
) -> bool:
    """Write the recovery marker, preserving any unspecified field from the
    existing on-disk content.

    Returns True when the marker changed, False on idempotent no-op.
    """
    existing = read_recovery_state(workspace_root) or {}
    final_phase = (
        last_completed_phase
        if last_completed_phase is not None
        else existing.get("Last completed phase", "—")
    )
    if in_flight_tasks is None:
        in_flight_str = existing.get("In-flight tasks", "none")
        final_tasks: Iterable[str] = (
            [t.strip() for t in in_flight_str.split(",") if t.strip() and t.strip() != "none"]
        )
    else:
        final_tasks = list(in_flight_tasks)
    if dirty_worktrees is None:
        dirty_str = existing.get("Dirty worktrees", "none")
        final_dirty: Iterable[str] = (
            [w.strip() for w in dirty_str.split(",") if w.strip() and w.strip() != "none"]
        )
    else:
        final_dirty = list(dirty_worktrees)
    final_ts = timestamp or _utc_now_str()

    content = _format_marker(
        last_completed_phase=final_phase,
        in_flight_tasks=final_tasks,
        dirty_worktrees=final_dirty,
        timestamp=final_ts,
    )
    return atomic_write(_marker_path(workspace_root), content)


def stamp_phase_exit(
    workspace_root: str | os.PathLike,
    phase_id: str,
    *,
    timestamp: Optional[str] = None,
) -> bool:
    """Rotate the marker after a successful phase exit (rotation point a)."""
    if not phase_id:
        raise ValueError("stamp_phase_exit: empty phase_id")
    return write_recovery_state(
        workspace_root,
        last_completed_phase=phase_id,
        timestamp=timestamp,
    )


def stamp_tracker_state(
    workspace_root: str | os.PathLike,
    tracker_path: str | os.PathLike,
    *,
    timestamp: Optional[str] = None,
) -> bool:
    """Rotate the marker on tracker transition (rotation point b).

    Reads the tracker and rolls up `In-flight tasks` from rows whose Status
    column contains the in-progress emoji (🔧).
    """
    path = Path(tracker_path)
    if not path.is_file():
        return write_recovery_state(workspace_root, in_flight_tasks=[], timestamp=timestamp)
    text = path.read_text(encoding="utf-8")
    in_flight: list[str] = []
    for line in text.splitlines():
        if not line.lstrip().startswith("|"):
            continue
        # Look for `T<n>` cell and an `🔧` cell on the same row.
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        task_id = None
        is_in_progress = False
        for c in cells:
            if re.match(r"^T[\w.-]*$", c) and not task_id:
                task_id = c
            if "🔧" in c:
                is_in_progress = True
        if task_id and is_in_progress:
            in_flight.append(task_id)
    return write_recovery_state(
        workspace_root,
        in_flight_tasks=in_flight,
        timestamp=timestamp,
    )


def stamp_gate_prompt(
    workspace_root: str | os.PathLike,
    gate_id: str,
    *,
    timestamp: Optional[str] = None,
) -> bool:
    """Rotate the marker at a gate prompt (rotation point c).

    Stores the gate label in `Last completed phase` so R Step 4 can resume
    *to* the gate, not before it. The convention is `gate-prompt:<gate_id>`
    to distinguish from a phase exit.
    """
    if not gate_id:
        raise ValueError("stamp_gate_prompt: empty gate_id")
    return write_recovery_state(
        workspace_root,
        last_completed_phase=f"gate-prompt:{gate_id}",
        timestamp=timestamp,
    )


def resume_label(workspace_root: str | os.PathLike) -> str:
    """Return a one-line human-readable resume hint for the marker.

    Created by IMPL-22-11 (M-22); merged into this module per the third-pass
    patch (CC-08.1 — single marker-domain module).

    Format:
        "Resume from <phase> — <n> in-flight task(s); <m> dirty worktree(s)"

    When the marker is absent, returns "No recovery state on disk".
    """
    state = read_recovery_state(workspace_root)
    if state is None:
        return "No recovery state on disk"
    phase = state.get("Last completed phase", "—")
    in_flight = state.get("In-flight tasks", "none")
    dirty = state.get("Dirty worktrees", "none")
    n_in_flight = 0 if in_flight in ("", "none") else len([t for t in in_flight.split(",") if t.strip()])
    n_dirty = 0 if dirty in ("", "none") else len([w for w in dirty.split(",") if w.strip()])
    return (
        f"Resume from {phase} — {n_in_flight} in-flight task(s); {n_dirty} dirty worktree(s)"
    )

#!/usr/bin/env python3
"""Mode-aware activation guard for the Tester subagent.

auto-tdd mode (Phase 3):
    Allow when the tracker has at least one task in 🔧 In Progress. The
    orchestrator only launches the Tester after marking a task In Progress,
    so this is a sanity check rather than a hard block.

auto-harden mode (Phase 5):
    Block unless every development task (T1, T2, …) is ✅ Done. T-TEST
    rows (Phase 5 hardening tasks) are excluded from this check.

Mode detection:
    Reads CLAUDE_SUBAGENT_PROMPT from the environment (populated by the
    harness at SubagentStart). Falls back to auto-harden (the stricter
    check) when the mode cannot be determined.

Column detection:
    Status column position is discovered from the tracker header row
    (case-insensitive match on "Status"). This replaces the previous
    fixed-index `$4`/`$5` awk that broke whenever a new column was added.
    If the header has no Status column the tracker schema is broken —
    block with a clear error.

Reads the hook payload file path from argv[1] (currently unused — the
guard inspects the workspace tracker directly — but the path is accepted
to stay consistent with the rest of the hook helpers).

Exit 0 = allow, Exit 2 = block.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path


# Legacy tracker directory; the new per-workflow layout
# (`ai/<YYYY-MM-DD>-<work-item-id>/tracker.md`) is supported additively by
# `_iter_tracker_files()` below (M-14 IMPL-14-05).
_TASKS_DIR = Path("ai/tasks")
_PER_WORKFLOW_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-[\w.-]+$")


def _iter_tracker_files() -> list[Path]:
    """Return every tracker file under `ai/` — legacy (`ai/tasks/*.md`) and
    new (`ai/<YYYY-MM-DD>-<work-item-id>/tracker.md`). Falls back to the
    legacy list when the new layout has no entries — preserves pre-migration
    behaviour.
    """
    files: list[Path] = []
    ai_root = Path("ai")
    if not ai_root.is_dir():
        return files
    # New per-workflow layout — one tracker per directory.
    for child in sorted(ai_root.iterdir(), reverse=True):
        if not child.is_dir():
            continue
        if not _PER_WORKFLOW_RE.match(child.name):
            continue
        tracker = child / "tracker.md"
        if tracker.is_file():
            files.append(tracker)
    # Legacy layout.
    if _TASKS_DIR.is_dir():
        files.extend(sorted(_TASKS_DIR.glob("*.md"), reverse=True))
    return files
_TASK_ID_RE = re.compile(r"^T\d+$")
_T_TEST_RE = re.compile(r"^T-TEST", re.IGNORECASE)
_HEADER_SEPARATOR_RE = re.compile(r"^\s*\|?\s*:?-{2,}")


_VALID_MODES = ("auto-tdd", "auto-harden")


def _detect_mode(argv: list[str] | None = None) -> str:
    """Detect the Tester mode.

    Preference order (M-10 IMPL-10-02):
        1. `--mode auto-tdd|auto-harden` flag in argv — orchestrator-side
           contract introduced in M-10 IMPL-10-01.
        2. `CLAUDE_SUBAGENT_PROMPT` env-var keyword scan — legacy fallback.
           When this path triggers, a deprecation warning is emitted to
           stderr (TEST-56).
        3. Default to `auto-harden` (stricter check) when neither resolves.
    """
    src = argv if argv is not None else sys.argv[1:]
    # Scan for `--mode <value>` or `--mode=<value>`.
    for i, tok in enumerate(src):
        if tok == "--mode" and i + 1 < len(src):
            val = src[i + 1].strip().lower()
            if val in _VALID_MODES:
                return val
        elif tok.startswith("--mode="):
            val = tok[len("--mode="):].strip().lower()
            if val in _VALID_MODES:
                return val

    # Legacy env-var fallback.
    prompt = os.environ.get("CLAUDE_SUBAGENT_PROMPT", "")
    low = prompt.lower()
    if "auto-tdd" in low or "auto-harden" in low:
        print(
            "tester-activation-guard: DEPRECATION — mode resolved via "
            "CLAUDE_SUBAGENT_PROMPT env var. Prefer `--mode auto-tdd` or "
            "`--mode auto-harden` from the orchestrator-side spawn (M-10 IMPL-10-01).",
            file=sys.stderr,
        )
        if "auto-tdd" in low:
            return "auto-tdd"
        return "auto-harden"
    return "auto-harden"


def _split_row(line: str) -> list[str]:
    """Split a markdown table row into trimmed cells, dropping the leading/
    trailing empties produced by the outer pipes."""
    parts = [c.strip() for c in line.split("|")]
    if parts and parts[0] == "":
        parts = parts[1:]
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return parts


def _is_table_row(line: str) -> bool:
    return line.lstrip().startswith("|")


def _is_separator_row(line: str) -> bool:
    cells = _split_row(line)
    return bool(cells) and all(_HEADER_SEPARATOR_RE.match(c) or c == "" for c in cells)


def _find_status_col(header: list[str]) -> int | None:
    for i, cell in enumerate(header):
        if cell.strip().lower() == "status":
            return i
    return None


def _find_task_id_col(header: list[str]) -> int | None:
    for i, cell in enumerate(header):
        low = cell.strip().lower()
        if low in {"task", "task id", "id"}:
            return i
    return None


def _iter_task_rows(content: str):
    """Yield (task_id, status_cell) tuples for every task row in the file.

    Resolves column positions by header (case-insensitive). Skips the
    header and separator rows. Yields a sentinel tuple ('__SCHEMA_ERROR__',
    reason) if the header is missing required columns — the caller blocks
    on that.
    """
    lines = content.splitlines()
    header_cells: list[str] | None = None
    status_idx: int | None = None
    task_id_idx: int | None = None

    i = 0
    while i < len(lines):
        line = lines[i]
        if not _is_table_row(line):
            i += 1
            continue

        cells = _split_row(line)
        if header_cells is None:
            # First table row is the header. The next row should be the
            # separator (---|---|...). If it isn't, this isn't really a
            # table — skip.
            if i + 1 < len(lines) and _is_separator_row(lines[i + 1]):
                header_cells = cells
                status_idx = _find_status_col(header_cells)
                task_id_idx = _find_task_id_col(header_cells)
                if status_idx is None or task_id_idx is None:
                    missing = []
                    if task_id_idx is None:
                        missing.append("Task")
                    if status_idx is None:
                        missing.append("Status")
                    yield ("__SCHEMA_ERROR__", "missing column(s): " + ", ".join(missing))
                    return
                i += 2  # skip header + separator
                continue
            else:
                i += 1
                continue

        # Body row
        if status_idx is None or task_id_idx is None:
            i += 1
            continue
        if task_id_idx >= len(cells) or status_idx >= len(cells):
            i += 1
            continue
        task_id = cells[task_id_idx]
        status = cells[status_idx]
        yield (task_id, status)
        i += 1


def _check_auto_tdd(tracker_files: list[Path]) -> tuple[bool, str]:
    in_progress_found = False
    for f in tracker_files:
        try:
            content = f.read_text(encoding="utf-8")
        except OSError:
            continue
        for task_id, status in _iter_task_rows(content):
            if task_id == "__SCHEMA_ERROR__":
                return False, (
                    f"Tracker schema invalid in {f}: {status}. "
                    f"Expected columns include 'Task' and 'Status'."
                )
            if not _TASK_ID_RE.match(task_id):
                continue
            if "🔧" in status:
                in_progress_found = True
    if not in_progress_found:
        return False, (
            "BLOCKED (auto-tdd): No task is currently 🔧 In Progress.\n"
            "The orchestrator must update the tracker to In Progress before "
            "launching the Tester."
        )
    return True, "✅ Tester activation check passed (auto-tdd) — task is In Progress."


def _check_auto_harden(tracker_files: list[Path]) -> tuple[bool, str]:
    incomplete: list[tuple[str, str]] = []
    for f in tracker_files:
        try:
            content = f.read_text(encoding="utf-8")
        except OSError:
            continue
        for task_id, status in _iter_task_rows(content):
            if task_id == "__SCHEMA_ERROR__":
                return False, (
                    f"Tracker schema invalid in {f}: {status}. "
                    f"Expected columns include 'Task' and 'Status'."
                )
            if _T_TEST_RE.match(task_id):
                continue
            if not _TASK_ID_RE.match(task_id):
                continue
            if "✅" not in status:
                incomplete.append((task_id, status))
    if incomplete:
        lines = ["BLOCKED (auto-harden): Cannot start Test Hardening — not all development tasks are complete.", ""]
        lines.append("Incomplete tasks:")
        for tid, st in incomplete:
            lines.append(f"  - {tid}: {st}")
        lines.append("")
        lines.append("All development tasks (T1, T2, ...) must be ✅ Done before Test Hardening begins.")
        lines.append("Return to Phase 3 to complete the remaining tasks.")
        return False, "\n".join(lines)
    return True, "✅ Tester activation check passed (auto-harden) — all development tasks are Done."


def main() -> int:
    tracker_files = _iter_tracker_files()
    if not tracker_files:
        # Distinguish "no ai/ tree at all" from "ai/ exists but no tracker"
        # for diagnostic clarity. Both block.
        if not Path("ai").is_dir():
            print(
                f"BLOCKED: No task tracker directory found at {_TASKS_DIR} (or per-workflow layout).",
                file=sys.stderr,
            )
            print(
                "The Planner agent must create tracker files before testing can begin.",
                file=sys.stderr,
            )
        else:
            print(
                "BLOCKED: No task tracker files found. Cannot verify workflow state.",
                file=sys.stderr,
            )
        return 2

    mode = _detect_mode()
    if mode == "auto-tdd":
        ok, msg = _check_auto_tdd(tracker_files)
    else:
        ok, msg = _check_auto_harden(tracker_files)

    if ok:
        print(msg)
        return 0
    print(msg, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

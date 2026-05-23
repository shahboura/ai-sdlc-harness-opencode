#!/usr/bin/env python3
"""metrics_collector — workflow metrics aggregator (IMPL-17-03, IMPL-25-03).

Pure data aggregator. Reads a per-workflow tracker, computes the six
required workflow aggregates per `skills/metrics-collector/SKILL.md`, and
emits:
  - `<workflow_dir>/metrics-report.md`  (per-workflow report)
  - `ai/_metrics-log.csv`               (append-only workspace CSV)

Plus stamps the tracker with `Metrics collected <ts> — round <n>`.

No agent reasoning. Invoked by the orchestrator as a subprocess.

Usage:
    python3 scripts/metrics_collector.py <workflow_dir> --round <n>

Where:
    <workflow_dir>  Path to `ai/<YYYY-MM-DD>-<safe-id>/` containing
                    `tracker.md` (or `tracker.archived.md` post-T3).
    --round <n>     `0` (T1 — PR creation), `1..N` (T2 — review round),
                    or `final` (T3 — reconcile).

Exit codes:
    0   success — outputs written, tracker stamped.
    1   skill-level failure (validation failure, IO error). An `.error.md`
        sibling is written; the CSV is NOT appended on failure.
    2   precondition not met (workflow dir / tracker absent).

Schema changelog:
    v1.0.0  Original 12 columns (IMPL-17-04).
    v1.1.0  Added tokens_input, tokens_output, tokens_cache_read,
            tokens_cache_write (orchestrator-aggregated per ADR-002;
            null until metrics-token-collector.sh hook lands in US-E02-003)
            and mode (quick|full per FR-1.7 / tracker-field-schema.md v1.1).

Created by: dev-workflow-plan.md [M-17] [IMPL-17-03], [M-25] [IMPL-25-03]
CC conventions applied: CC-01.5 (exit codes), CC-02.4.2 (token fields null-safe),
                        CC-04.3, CC-05.7, CC-05.3, ADR-002.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

SCHEMA_VERSION = "1.1.0"
METRICS_CSV_FILENAME = "_metrics-log.csv"

# Canonical timestamp format per CC-05.3.
TS_FMT = "%Y-%m-%d %H:%M UTC"

# CSV columns for v1.1.0 schema (IMPL-17-04 base + IMPL-25-03 additions).
CSV_COLUMNS = [
    "schema_version",
    "work_item_id",
    "round",
    "timestamp_utc",
    "cycle_time_minutes",
    "p3_duration_minutes",
    "p5_duration_minutes",
    "p7_duration_minutes",
    "reviewer_rework_rounds",
    "pr_review_rounds",
    "coverage_pct",
    "defect_escape_count",
    # v1.1.0 additions (IMPL-25-03)
    # Populated by metrics-token-collector.sh (US-E02-003); null until that hook lands.
    # ADR-002: orchestrator-aggregated from PostToolUse payloads, never agent self-report.
    "tokens_input",
    "tokens_output",
    "tokens_cache_read",
    "tokens_cache_write",
    # Workflow mode per FR-1.7 / tracker-field-schema.md v1.1.
    "mode",
]

# v1.0.0 column set — used to detect files that need migration.
_V1_0_COLUMNS = [
    "schema_version",
    "work_item_id",
    "round",
    "timestamp_utc",
    "cycle_time_minutes",
    "p3_duration_minutes",
    "p5_duration_minutes",
    "p7_duration_minutes",
    "reviewer_rework_rounds",
    "pr_review_rounds",
    "coverage_pct",
    "defect_escape_count",
]

# Sentinel used when token data is unavailable (ADR-002 null-safe contract).
_TOKEN_UNAVAILABLE = ""

# Human-friendly labels for the Aggregates + Token Usage tables in
# `metrics-report.md`. CSV column names (raw snake_case keys) are NEVER
# rewritten — the CSV is a machine-readable contract; only the markdown
# report uses these display labels.
_HUMAN_LABELS: Dict[str, str] = {
    "cycle_time_minutes": "Cycle time (plan approved → PR created)",
    "p3_duration_minutes": "P3 — Development",
    "p5_duration_minutes": "P5 — Test hardening",
    "p7_duration_minutes": "P7 — Review response",
    "reviewer_rework_rounds": "Reviewer rework rounds",
    "pr_review_rounds": "PR review cycles",
    "coverage_pct": "Coverage (post-hardening)",
    "defect_escape_count": "Defects escaped to PR review",
    "tokens_input": "Tokens — input",
    "tokens_output": "Tokens — output",
    "tokens_cache_read": "Tokens — cache read",
    "tokens_cache_write": "Tokens — cache write",
    "mode": "Mode",
}

# Aggregate keys whose value is a minute-count and should render as `Xh YYm`
# (or `YYm` when < 60) in the markdown report.
_DURATION_KEYS = {
    "cycle_time_minutes",
    "p3_duration_minutes",
    "p5_duration_minutes",
    "p7_duration_minutes",
}

# Aggregate keys whose value is a token integer and should render with
# thousands separators (e.g. 93028671 → "93,028,671") in the markdown report.
_TOKEN_KEYS = {
    "tokens_input",
    "tokens_output",
    "tokens_cache_read",
    "tokens_cache_write",
}

# Phase definitions for the Phase Summary table (label, start_stamp_key,
# end_stamp_key). A phase row appears only when BOTH stamps are present
# in the tracker — partial workflows (no review cycles, no security
# review, etc.) silently skip the rows they didn't reach. Order matches
# the workflow's execution sequence so the rendered table reads
# top-to-bottom in time order.
#
# CC-04.5 — single declaration of phase labels; renderers MUST NOT
# duplicate these strings inline.
_PHASE_DEFINITIONS: List[Tuple[str, str, str]] = [
    ("P1 — Requirements",      "Workflow started",             "Plan approved"),
    ("P2 — Planning",          "Plan approved",                "Development started"),
    ("P3 — Development",       "Development started",          "Initial development completed"),
    ("P4 — Approval gate",     "Initial development completed", "Human approval (impl)"),
    ("P5 — Test hardening",    "Test hardening started",       "Test hardening completed"),
    ("P5.5 — Security review", "Test hardening completed",     "Security review completed"),
    ("P6 — PR creation",       "Security review completed",    "PR created"),
    ("P7 — Review response",   "PR created",                   "PR review response completed"),
]


def _parse_timestamp(s: str) -> Optional[dt.datetime]:
    s = s.strip()
    if not s or s == "—" or s.lower() == "n/a":
        return None
    try:
        return dt.datetime.strptime(s, TS_FMT)
    except ValueError:
        return None


def _utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime(TS_FMT)


def _resolve_tracker(workflow_dir: Path) -> Optional[Path]:
    for name in ("tracker.archived.md", "tracker.md"):
        p = workflow_dir / name
        if p.is_file():
            return p
    return None


_METRIC_LINE = re.compile(r"^([A-Z][A-Za-z0-9 ()/_,-]+?):\s*(.+?)\s*$", re.MULTILINE)


def _parse_workflow_metrics(tracker_text: str) -> Dict[str, str]:
    """Extract field→value pairs from the `## Workflow Metrics` section.

    Accepts two formats produced by different tracker generations:

    * **Legacy (pre-v2.1)** — plain `Field: value` lines, one per stamp.
    * **Canonical (v2.1+)** — markdown table rows `| **Field** | value |`
      under a `| Metric | Value |` header. The bold-asterisk wrapping is
      the discriminator that distinguishes a metric row from the table
      header / separator row, and from `### Task Metrics` rows (which
      have no bold).

    Body scan stops at the next H2 **or** H3 so the `### Task Metrics`
    sub-section that the canonical layout nests inside `## Workflow Metrics`
    isn't mis-parsed as workflow stamps.
    """
    m = re.search(r"^##\s+Workflow Metrics\s*$", tracker_text, flags=re.MULTILINE)
    if not m:
        return {}
    body = tracker_text[m.end():]
    next_section = re.search(r"^#{2,3}\s+\S", body, flags=re.MULTILINE)
    if next_section:
        body = body[: next_section.start()]
    out: Dict[str, str] = {}
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # Legacy: plain `Field: value`.
        legacy = re.match(r"^([A-Z][A-Za-z0-9 ()/_-]+?):\s*(.+?)\s*$", line)
        if legacy:
            out[legacy.group(1).strip()] = legacy.group(2).strip()
            continue
        # Canonical (v2.1+): `| **Field** | value |` markdown table row.
        # The bold wrapping excludes the table header `| Metric | Value |`
        # and the separator `|--------|-------|` automatically.
        canonical = re.match(r"^\|\s*\*\*([^|*]+?)\*\*\s*\|\s*(.+?)\s*\|", line)
        if canonical:
            out[canonical.group(1).strip()] = canonical.group(2).strip()
    return out


_TASK_ROW_RE = re.compile(r"^\|\s*(T[\w.-]+)\s*\|", re.MULTILINE)
_TASK_ID_RE = re.compile(r"^T[\w.-]+$")


def _parse_pipe_table(body: str) -> List[Dict[str, str]]:
    """Parse a markdown pipe table whose first cell per row is a task ID.

    Returns one {column_name: cell_value} dict per data row. The header
    line is assumed to be the first `|`-prefixed line; the second is the
    `|---|---|` separator (skipped). Only rows whose first cell matches
    `T<n>` / `T-TEST-<repo>` are returned — header / decoration noise is
    filtered out.
    """
    lines = [line for line in body.splitlines() if line.strip().startswith("|")]
    if len(lines) < 2:
        return []
    header_cells = [c.strip() for c in lines[0].strip().strip("|").split("|")]
    rows: List[Dict[str, str]] = []
    for line in lines[2:]:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != len(header_cells):
            continue
        row = dict(zip(header_cells, cells))
        first_col = next(iter(row.values()), "")
        if _TASK_ID_RE.match(first_col):
            rows.append(row)
    return rows


def _slice_section(tracker_text: str, heading_re: str) -> Optional[str]:
    """Return the body between a heading and the next same-or-higher
    heading. Returns None if the heading is absent."""
    m = re.search(heading_re, tracker_text, flags=re.MULTILINE)
    if not m:
        return None
    body = tracker_text[m.end():]
    next_section = re.search(r"^#{1,3}\s+\S", body, flags=re.MULTILINE)
    if next_section:
        body = body[: next_section.start()]
    return body


def _parse_task_metrics_section(tracker_text: str) -> List[Dict[str, str]]:
    """Parse the canonical `### Task Metrics` sub-section table (v2.1+)."""
    body = _slice_section(tracker_text, r"^###\s+Task Metrics\s*$")
    return _parse_pipe_table(body) if body is not None else []


def _parse_top_level_task_table(tracker_text: str) -> List[Dict[str, str]]:
    """Parse the top-level Tasks table that v2.1+ places directly after
    the H1 (no `## Tasks` heading)."""
    first_h2 = re.search(r"^##\s+\S", tracker_text, flags=re.MULTILINE)
    body = tracker_text[: first_h2.start()] if first_h2 else tracker_text
    return _parse_pipe_table(body)


def _parse_task_rows(tracker_text: str) -> List[Dict[str, str]]:
    """Parse task rows from the tracker, tolerating both layouts.

    * **Canonical (v2.1+)** — top-level Tasks table (no heading) holds
      `Task ID | Repo | Title | Status | Reviewer Verdict | Commit(s) | Notes`;
      `### Task Metrics` under `## Workflow Metrics` holds
      `Task ID | Started | Completed | Review Rounds | Build Retries | Test Written | Green At`.
      The two are merged by Task ID so the report has both Status and metrics.
    * **Legacy (pre-v2.1)** — single `## Tasks` table with metric columns
      embedded inline. Returned as-is.
    """
    canonical_metrics = _parse_task_metrics_section(tracker_text)
    if canonical_metrics:
        top_rows = _parse_top_level_task_table(tracker_text)
        top_by_id = {next(iter(row.values()), ""): row for row in top_rows}
        for row in canonical_metrics:
            task_id = next(iter(row.values()), "")
            top_row = top_by_id.get(task_id)
            if top_row:
                # Add Status / Reviewer Verdict / Notes without overwriting
                # the metric columns the canonical Task Metrics table owns.
                for col, val in top_row.items():
                    row.setdefault(col, val)
        return canonical_metrics

    body = _slice_section(tracker_text, r"^##\s+Tasks\s*$")
    return _parse_pipe_table(body) if body is not None else []


def _minutes_between(start: Optional[dt.datetime], end: Optional[dt.datetime]) -> Optional[int]:
    if start is None or end is None:
        return None
    if end < start:
        return None
    return int((end - start).total_seconds() // 60)


def _sum_review_rounds(tasks: List[Dict[str, str]]) -> int:
    total = 0
    for row in tasks:
        rr = row.get("Review Rounds", "").strip()
        try:
            total += int(rr)
        except (TypeError, ValueError):
            pass
    return total


def _extract_coverage(workflow_metrics: Dict[str, str]) -> Optional[float]:
    val = workflow_metrics.get("Final coverage") or workflow_metrics.get("Coverage")
    if not val:
        return None
    m = re.search(r"(\d+(?:\.\d+)?)", val)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def _extract_mode(tracker_text: str) -> str:
    """Extract the workflow mode from tracker front-matter.

    Returns "quick" if the tracker contains `Mode: quick`, else "full"
    (the default for pre-v2.1 trackers that pre-date the Mode: field).
    Per FR-1.7 and tracker-field-schema.md v1.1.
    """
    m = re.search(r"^Mode:\s*(\S+)", tracker_text, re.MULTILINE | re.IGNORECASE)
    if m:
        val = m.group(1).strip().lower()
        return "quick" if val == "quick" else "full"
    return "full"


def _load_token_totals(workflow_dir: Path) -> Dict[str, str]:
    """Aggregate token usage from `.token-log.jsonl` in the workflow dir.

    Returns a dict with keys tokens_input, tokens_output, tokens_cache_read,
    tokens_cache_write — all empty strings when the log is absent or
    when a provider did not populate usage fields (ADR-002 null-safe contract).

    The .token-log.jsonl is written by metrics-token-collector.sh (US-E02-003).
    Until that hook lands, this function always returns empty values.
    """
    import json  # stdlib, local import to keep the top-level clean

    null_result: Dict[str, str] = {
        "tokens_input": _TOKEN_UNAVAILABLE,
        "tokens_output": _TOKEN_UNAVAILABLE,
        "tokens_cache_read": _TOKEN_UNAVAILABLE,
        "tokens_cache_write": _TOKEN_UNAVAILABLE,
    }

    log_path = workflow_dir / ".token-log.jsonl"
    if not log_path.is_file():
        return null_result

    totals: Dict[str, int] = {
        "tokens_input": 0,
        "tokens_output": 0,
        "tokens_cache_read": 0,
        "tokens_cache_write": 0,
    }
    any_data = False
    try:
        for line in log_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            for key in totals:
                v = entry.get(key)
                if v is not None:
                    try:
                        totals[key] += int(v)
                        any_data = True
                    except (TypeError, ValueError):
                        pass
    except (OSError, UnicodeDecodeError):
        return null_result

    if not any_data:
        return null_result
    return {k: str(v) for k, v in totals.items()}


def _token_window_bucket(
    workflow_dir: Path,
    windows: List[Tuple[str, dt.datetime, dt.datetime]],
) -> Dict[str, Dict[str, int]]:
    """Bucket `.token-log.jsonl` entries into named time windows.

    Iterates the log once and attributes each entry to the FIRST window
    whose `[start, end]` (inclusive) contains the entry's `ts`. The
    first-match-wins rule keeps the bucketing deterministic when phases
    or parallel-repo tasks overlap (e.g. P5.5 / P6 sequential stamps,
    or T1 on AuthService running concurrently with T1' on BillingService).

    Returns a dict keyed by window label, each value a four-key totals
    dict (`tokens_input`, `tokens_output`, `tokens_cache_read`,
    `tokens_cache_write`) plus `entry_count`. Windows with no matching
    log entries return zero-filled totals (caller decides whether to
    render as `0` or `—`).

    Per CC-08.1 this is the single bucketing primitive used by both
    `_render_phase_summary` and the per-task summary; duplicating the
    JSONL iteration loop would be a CC-04.5 drift surface.
    """
    import json  # local — keep top-level imports lean

    keys = ("tokens_input", "tokens_output", "tokens_cache_read", "tokens_cache_write")
    out: Dict[str, Dict[str, int]] = {
        label: {k: 0 for k in keys} | {"entry_count": 0}
        for label, _, _ in windows
    }
    log_path = workflow_dir / ".token-log.jsonl"
    if not log_path.is_file() or not windows:
        return out

    try:
        for line in log_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = _parse_timestamp(entry.get("ts", ""))
            if ts is None:
                continue
            for label, start, end in windows:
                if start <= ts <= end:
                    for k in keys:
                        v = entry.get(k)
                        if v is not None:
                            try:
                                out[label][k] += int(v)
                            except (TypeError, ValueError):
                                pass
                    out[label]["entry_count"] += 1
                    break  # first-match-wins; do not double-count overlapping windows
    except (OSError, UnicodeDecodeError):
        pass
    return out


def _migrate_csv_if_needed(csv_path: Path) -> None:
    """Upgrade a v1.0.0 `_metrics-log.csv` to v1.1.0 in place.

    - No-op when the file is already v1.1.0 (idempotent).
    - No-op when the file does not exist (caller handles the new-file path).
    - Rewrites the file atomically (tmp → rename) when migration is needed.
    - Old rows keep their original `schema_version` value ("1.0.0") so
      downstream consumers can distinguish pre-v1.1.0 rows.
    - New columns are padded with '' for old rows per ADR-002 null-safe contract.
    """
    if not csv_path.exists():
        return

    with csv_path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        if not reader.fieldnames:
            return  # empty or header-only file with no usable header
        existing_cols = list(reader.fieldnames)
        # Already up-to-date if all v1.1.0 columns are present.
        if all(c in existing_cols for c in CSV_COLUMNS):
            return
        rows = list(reader)

    tmp = csv_path.with_suffix(".csv.migration_tmp")
    try:
        with tmp.open("w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=CSV_COLUMNS, extrasaction="ignore")
            writer.writeheader()
            for row in rows:
                padded = {col: row.get(col, "") for col in CSV_COLUMNS}
                # Preserve the original schema_version on old rows so downstream
                # BI can identify pre-v1.1 rows (do NOT overwrite with "1.1.0").
                writer.writerow(padded)
        tmp.replace(csv_path)
    except Exception:  # pylint: disable=broad-except
        tmp.unlink(missing_ok=True)
        raise


def _count_pr_review_rounds(workflow_dir: Path) -> int:
    return len(list(workflow_dir.glob("pr-comment-analysis-report-*.md")))


def _count_defect_escapes(workflow_dir: Path) -> int:
    total = 0
    for f in workflow_dir.glob("pr-comment-analysis-report-*.md"):
        try:
            text = f.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        total += len(re.findall(r"^\s*\[S\d+\]", text, flags=re.MULTILINE))
    return total


def _validate(workflow_metrics: Dict[str, str], tasks: List[Dict[str, str]]) -> Optional[str]:
    """Per CC-01.5: refuse if a Completed stamp precedes its Started counterpart."""
    for row in tasks:
        started = _parse_timestamp(row.get("Started", ""))
        completed = _parse_timestamp(row.get("Completed", ""))
        if started and completed and completed < started:
            task_id = next(iter(row.values()), "?")
            return (
                f"task {task_id} has Completed ({row.get('Completed')}) before "
                f"Started ({row.get('Started')})"
            )
    plan_approved = _parse_timestamp(workflow_metrics.get("Plan approved", ""))
    dev_started = _parse_timestamp(workflow_metrics.get("Development started", ""))
    if plan_approved and dev_started and dev_started < plan_approved:
        return (
            f"Development started ({workflow_metrics.get('Development started')}) "
            f"precedes Plan approved ({workflow_metrics.get('Plan approved')})"
        )
    return None


def _compute_aggregates(
    workflow_metrics: Dict[str, str],
    tasks: List[Dict[str, str]],
    workflow_dir: Path,
    mode: str = "full",
) -> Dict[str, object]:
    plan_approved = _parse_timestamp(workflow_metrics.get("Plan approved", ""))
    dev_started = _parse_timestamp(workflow_metrics.get("Development started", ""))
    # Cover the post-rename `Initial development completed` as well as the
    # legacy `Development completed`.
    dev_completed = _parse_timestamp(
        workflow_metrics.get("Initial development completed", "")
        or workflow_metrics.get("Development completed", "")
    )
    th_started = _parse_timestamp(workflow_metrics.get("Test hardening started", ""))
    th_completed = _parse_timestamp(workflow_metrics.get("Test hardening completed", ""))
    pr_created = _parse_timestamp(
        workflow_metrics.get("PR created", "")
        or workflow_metrics.get("PR-Opened", "")
    )
    pr_resp_completed = _parse_timestamp(
        workflow_metrics.get("PR review response completed", "")
    )

    token_totals = _load_token_totals(workflow_dir)
    return {
        "cycle_time_minutes": _minutes_between(plan_approved, pr_created),
        "p3_duration_minutes": _minutes_between(dev_started, dev_completed),
        "p5_duration_minutes": _minutes_between(th_started, th_completed),
        "p7_duration_minutes": _minutes_between(pr_created, pr_resp_completed),
        "reviewer_rework_rounds": _sum_review_rounds(tasks),
        "pr_review_rounds": _count_pr_review_rounds(workflow_dir),
        "coverage_pct": _extract_coverage(workflow_metrics),
        "defect_escape_count": _count_defect_escapes(workflow_dir),
        # v1.1.0 fields — null (empty string) until US-E02-003 hook lands.
        "tokens_input": token_totals["tokens_input"],
        "tokens_output": token_totals["tokens_output"],
        "tokens_cache_read": token_totals["tokens_cache_read"],
        "tokens_cache_write": token_totals["tokens_cache_write"],
        "mode": mode,
    }


def _format_duration(minutes: object) -> Optional[str]:
    """Convert a minute count into `Xh YYm` (or `YYm` when < 60).

    Returns None for None / empty / non-numeric — callers render the
    missing-value sentinel themselves so they can also attach a reason.
    """
    if minutes is None or minutes == "":
        return None
    try:
        m = int(minutes)
    except (TypeError, ValueError):
        return None
    if m < 60:
        return f"{m}m"
    h, mm = divmod(m, 60)
    return f"{h}h {mm:02d}m"


def _format_tokens(count: object) -> Optional[str]:
    """Format a token integer with thousands separators. None on missing."""
    if count is None or count == "":
        return None
    try:
        return f"{int(count):,}"
    except (TypeError, ValueError):
        return None


def _human_label(key: str) -> str:
    """Humanised label for an aggregate key. Falls back to spaces-from-snake_case."""
    return _HUMAN_LABELS.get(key, key.replace("_", " "))


def _missing_reason(
    key: str,
    workflow_metrics: Dict[str, str],
    workflow_dir: Path,
) -> Optional[str]:
    """Why is the aggregate value missing? Returns None when unknown
    (caller falls back to a plain `—`)."""
    if key == "cycle_time_minutes":
        if not (workflow_metrics.get("PR created") or workflow_metrics.get("PR-Opened")):
            return "PR not yet created"
    elif key == "p7_duration_minutes":
        if not list(workflow_dir.glob("pr-comment-analysis-report-*.md")):
            return "no review cycles"
    elif key == "coverage_pct":
        if not (workflow_metrics.get("Coverage") or workflow_metrics.get("Final coverage")):
            return "no coverage report"
    return None


def _format_aggregate_value(
    key: str,
    value: object,
    workflow_metrics: Dict[str, str],
    workflow_dir: Path,
) -> str:
    """Render an aggregate value for the markdown Aggregates table.

    - Duration keys → `Xh YYm` / `YYm`.
    - Token keys → thousands-separated integer.
    - Empty / None → `—`, suffixed with `(reason)` when one is known.
    - Everything else → str(value).
    """
    if value is None or value == "":
        reason = _missing_reason(key, workflow_metrics, workflow_dir)
        return f"— ({reason})" if reason else "—"
    if key in _DURATION_KEYS:
        return _format_duration(value) or "—"
    if key in _TOKEN_KEYS:
        return _format_tokens(value) or "—"
    return str(value)


def _render_summary(aggregates: Dict[str, object], tasks: List[Dict[str, str]]) -> Optional[str]:
    """Build the top-line `> **Summary**:` blockquote contents.

    Pieces with no data are skipped rather than rendering `n/a`. Returns
    None when nothing is worth saying.
    """
    cycle = _format_duration(aggregates.get("cycle_time_minutes"))
    pieces: List[str] = []

    if tasks:
        n = len(tasks)
        mode = aggregates.get("mode", "full")
        suffix = "task" if n == 1 else "tasks"
        if cycle:
            pieces.append(f"{n} {suffix} ({mode} mode)")
        else:
            pieces.append(f"{n} {suffix} completed so far")

    rework = aggregates.get("reviewer_rework_rounds")
    if rework not in (None, ""):
        try:
            r = int(rework)
            pieces.append(f"{r} reviewer round" + ("s" if r != 1 else ""))
        except (TypeError, ValueError):
            pass

    defects = aggregates.get("defect_escape_count")
    if defects not in (None, ""):
        try:
            d = int(defects)
            pieces.append(f"{d} defect" + ("s" if d != 1 else "") + " escaped")
        except (TypeError, ValueError):
            pass

    if not pieces and not cycle:
        return None

    body = " · ".join(pieces)
    if cycle:
        return f"Story completed in {cycle}" + (f" · {body}" if body else "")
    return f"In progress — {body}" if body else "In progress"


def _render_timeline(workflow_metrics: Dict[str, str]) -> List[str]:
    """Render workflow stamps as a chronological phase timeline table.

    Drops `Metrics collected (N):` rows (meta, not phase events) and any
    stamp whose value isn't a parseable timestamp. Δ is computed from the
    earliest parseable stamp present. Returns the markdown lines (no
    trailing blank).
    """
    stamps: List[Tuple[dt.datetime, str, str]] = []
    for name, value in workflow_metrics.items():
        if name.lower().startswith("metrics collected"):
            continue
        ts = _parse_timestamp(value)
        if ts is None:
            continue
        stamps.append((ts, name, value))

    if not stamps:
        return ["(no phase stamps recorded)"]

    stamps.sort(key=lambda t: t[0])
    start = stamps[0][0]
    lines = [
        "| Stamp | UTC time | Δ from start |",
        "|---|---|---|",
    ]
    for ts, name, value in stamps:
        delta_min = int((ts - start).total_seconds() // 60)
        delta = _format_duration(delta_min) or "0m"
        lines.append(f"| {name} | {value} | {delta} |")
    return lines


def _compute_phase_windows(
    workflow_metrics: Dict[str, str],
) -> List[Tuple[str, dt.datetime, dt.datetime]]:
    """Build phase windows from `_PHASE_DEFINITIONS`. Skips phases whose
    start or end stamp is absent / unparseable."""
    out: List[Tuple[str, dt.datetime, dt.datetime]] = []
    for label, start_key, end_key in _PHASE_DEFINITIONS:
        start = _parse_timestamp(workflow_metrics.get(start_key, ""))
        end = _parse_timestamp(workflow_metrics.get(end_key, ""))
        if start and end and end >= start:
            out.append((label, start, end))
    return out


def _compute_task_windows(
    tasks: List[Dict[str, str]],
) -> List[Tuple[str, dt.datetime, dt.datetime]]:
    """Build per-task windows from the Task Metrics table's `Started` /
    `Completed` columns. Skips tasks lacking either stamp (typical for
    T-TEST rows that record only Phase 5 aggregate stamps)."""
    out: List[Tuple[str, dt.datetime, dt.datetime]] = []
    for row in tasks:
        task_id = next(iter(row.values()), "")
        start = _parse_timestamp(row.get("Started", ""))
        end = _parse_timestamp(row.get("Completed", ""))
        if task_id and start and end and end >= start:
            out.append((task_id, start, end))
    return out


def _render_phase_summary(
    workflow_metrics: Dict[str, str],
    workflow_dir: Path,
) -> List[str]:
    """Render the `## Phase Summary` section — per-phase Duration +
    token bucketing. Returns the markdown lines (no trailing blank).

    Skipped entirely when no phase windows can be computed (returns a
    single placeholder line). The Total row's Duration is the SUM of
    per-phase durations — i.e. time spent inside known phase windows;
    excludes gaps between phases. Wall-clock cycle time lives in the
    Aggregates table.
    """
    windows = _compute_phase_windows(workflow_metrics)
    if not windows:
        return ["(no phase windows available — workflow metrics block has no parseable phase boundary pairs)"]
    buckets = _token_window_bucket(workflow_dir, windows)

    lines = [
        "| Phase | Duration | Tokens (in / out) | Cache (read) |",
        "|---|---|---|---|",
    ]
    total_minutes = 0
    total_in = 0
    total_out = 0
    total_cr = 0
    for label, start, end in windows:
        minutes = int((end - start).total_seconds() // 60)
        total_minutes += minutes
        b = buckets.get(label, {})
        tin = b.get("tokens_input", 0)
        tout = b.get("tokens_output", 0)
        tcr = b.get("tokens_cache_read", 0)
        total_in += tin
        total_out += tout
        total_cr += tcr
        tokens_cell = (
            f"{_format_tokens(tin) or '0'} / {_format_tokens(tout) or '0'}"
            if (tin or tout)
            else "—"
        )
        cache_cell = _format_tokens(tcr) if tcr else "—"
        lines.append(
            f"| {label} | {_format_duration(minutes) or '0m'} | {tokens_cell} | {cache_cell} |"
        )
    total_tokens_cell = (
        f"{_format_tokens(total_in)} / {_format_tokens(total_out)}"
        if (total_in or total_out)
        else "—"
    )
    total_cache_cell = _format_tokens(total_cr) if total_cr else "—"
    lines.append(
        f"| **Total** | {_format_duration(total_minutes) or '0m'} | {total_tokens_cell} | {total_cache_cell} |"
    )
    lines.append("")
    lines.append(
        "*Short phases (typically < 10 min) may show “—” for tokens — "
        "Stop events fire at session boundaries, not phase boundaries, and short "
        "orchestrator-stamping intervals rarely contain a session-end timestamp. "
        "Non-LLM phases (e.g. Security review) emit no Stop events and will always show “—”.*"
    )
    return lines


def _render_report(
    workflow_dir: Path,
    work_item_id: str,
    round_label: str,
    workflow_metrics: Dict[str, str],
    tasks: List[Dict[str, str]],
    aggregates: Dict[str, object],
    generated_at: str,
) -> str:
    lines: List[str] = [
        f"# Metrics Report — {work_item_id}",
        "",
        f"> Generated: {generated_at}",
        f"> Round: {round_label}",
        f"> Workflow directory: {workflow_dir.name}",
    ]
    summary = _render_summary(aggregates, tasks)
    if summary:
        lines.append(f"> **Summary**: {summary}")
    lines.append("")

    lines.append("## Phase Summary")
    lines.append("")
    lines.extend(_render_phase_summary(workflow_metrics, workflow_dir))
    lines.append("")

    lines.append("## Aggregates")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("|---|---|")
    for k, v in aggregates.items():
        lines.append(
            f"| {_human_label(k)} | {_format_aggregate_value(k, v, workflow_metrics, workflow_dir)} |"
        )
    lines.append("")

    lines.append("## Per-Task Summary")
    lines.append("")
    if tasks:
        # Per-task token bucketing — first-match-wins by Started→Completed window.
        task_windows = _compute_task_windows(tasks)
        task_token_buckets = _token_window_bucket(workflow_dir, task_windows)

        lines.append("| Task | Status | Review Rounds | Started | Completed | Duration | Tokens (in + out) |")
        lines.append("|---|---|---|---|---|---|---|")
        for row in tasks:
            task_id = next(iter(row.values()), "?")
            start = _parse_timestamp(row.get("Started", ""))
            end = _parse_timestamp(row.get("Completed", ""))
            if start and end and end >= start:
                duration = _format_duration(int((end - start).total_seconds() // 60)) or "0m"
            else:
                duration = "—"
            bucket = task_token_buckets.get(task_id, {})
            tin = bucket.get("tokens_input", 0)
            tout = bucket.get("tokens_output", 0)
            tokens_cell = _format_tokens(tin + tout) if (tin or tout) else "—"
            lines.append(
                f"| {task_id} | {row.get('Status', '—')} | "
                f"{row.get('Review Rounds', '0')} | "
                f"{row.get('Started', '—')} | "
                f"{row.get('Completed', '—')} | "
                f"{duration} | {tokens_cell} |"
            )
        lines.append("")
        lines.append("*Per-task tokens are rough attribution by session timestamp; parallel tasks across repos may share credit.*")
    else:
        lines.append("(no task rows parsed)")
    lines.append("")

    lines.append("## Token Usage")
    lines.append("")
    lines.append("| Field | Value |")
    lines.append("|---|---|")
    for agg_key in ("tokens_input", "tokens_output", "tokens_cache_read", "tokens_cache_write"):
        raw = aggregates.get(agg_key, "")
        # CC-02.4.2 / ADR-002: empty string means the hook hasn't landed yet —
        # render "tokens unavailable" rather than "0" or blank.
        display = _format_tokens(raw) if raw not in (None, "") else "tokens unavailable"
        lines.append(f"| {_human_label(agg_key)} | {display} |")
    lines.append("")

    lines.append("## Phase Timeline")
    lines.append("")
    lines.extend(_render_timeline(workflow_metrics))
    lines.append("")
    return "\n".join(lines)


def _append_csv_row(
    csv_path: Path,
    work_item_id: str,
    round_label: str,
    generated_at: str,
    aggregates: Dict[str, object],
) -> None:
    """Append one v1.1.0 row to the CSV, migrating from v1.0.0 if needed.

    Migration is idempotent: safe to call on an already-v1.1.0 file.
    New files get the v1.1.0 header on first write.
    """
    _migrate_csv_if_needed(csv_path)
    new_file = not csv_path.exists()
    row: Dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "work_item_id": work_item_id,
        "round": round_label,
        "timestamp_utc": generated_at,
    }
    for key in CSV_COLUMNS:
        if key in row:
            continue
        v = aggregates.get(key)
        # None → "" (not "0") per CC-02.4.2 null-safe contract for token fields.
        row[key] = "" if v is None else v
    with csv_path.open("a", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_COLUMNS)
        if new_file:
            writer.writeheader()
        writer.writerow(row)


def _stamp_tracker(tracker_path: Path, round_label: str, generated_at: str) -> None:
    text = tracker_path.read_text(encoding="utf-8")
    stamp = f"Metrics collected ({round_label}): {generated_at}"
    pattern = re.compile(
        r"^Metrics collected \(" + re.escape(round_label) + r"\):.*$",
        re.MULTILINE,
    )
    if pattern.search(text):
        text = pattern.sub(stamp, text)
    elif re.search(r"^##\s+Workflow Metrics\s*$", text, flags=re.MULTILINE):
        text = re.sub(
            r"(^##\s+Workflow Metrics\s*\n)",
            r"\1\n" + stamp + "\n",
            text,
            count=1,
            flags=re.MULTILINE,
        )
    else:
        text = text.rstrip() + "\n\n" + stamp + "\n"
    tracker_path.write_text(text, encoding="utf-8")


def _write_error(workflow_dir: Path, cause: str) -> Path:
    err = workflow_dir / "metrics-report.error.md"
    err.write_text(
        f"# Metrics Collector Error\n\n**Cause**: {cause}\n\n"
        f"**Suggested remediation**: fix the tracker inconsistency, then re-run.\n",
        encoding="utf-8",
    )
    return err


def _check_round_preconditions(
    round_label: str,
    workflow_metrics: Dict[str, str],
    workflow_dir: Path,
) -> Optional[str]:
    """Defensive callee-side guard against premature trigger invocations.

    Each round label has an upstream tracker stamp / artifact that must
    exist before the metrics row is meaningful. The orchestrator-side
    command files (`create-pr.md` Step 10, `review-response.md` Step 10)
    already guard at the call site; this gate is the last-line defence
    so a misfired invocation can't silently produce a row with empty
    aggregates (the symptom observed in `harness-2.0/ai/2026-05-22-US-023`).

    Returns `None` when the preconditions hold; otherwise an explanation
    string suitable for the `.error.md` body. Caller emits exit 2 on
    non-None return.

    Honours CC-05.3 (explicit phase exit signal — phases finish by
    stamping a metric) and CC-05.4 (phase boundary enforcement at the
    tool layer): the collector refuses to produce an "I ran" row when
    the upstream phase did not actually publish its exit signal.
    """
    if round_label == "0":
        # T1 (PR creation) requires the `PR created` stamp; legacy
        # workflows used `PR-Opened` — accept either.
        if not (workflow_metrics.get("PR created") or workflow_metrics.get("PR-Opened")):
            return (
                "T1 (--round 0) requires the `PR created` stamp in the tracker's "
                "Workflow Metrics block; none found. Re-run `create-pr.md` Step 9 "
                "(stamp `PR created` via the Edit tool) before invoking T1 metrics."
            )
    elif round_label == "final":
        # T3 is intentionally lenient — the workflow may complete via
        # reconcile even with an unusual stamp set; the archived tracker's
        # existence (already checked at the call site) is sufficient.
        return None
    else:
        # T2 (--round 1..N) requires at least one
        # `pr-comment-analysis-report-*.md` artifact in the workflow dir
        # (the per-round P7 output). Without one, T2 has no trigger source.
        if not list(workflow_dir.glob("pr-comment-analysis-report-*.md")):
            return (
                f"T2 (--round {round_label}) requires at least one "
                f"`pr-comment-analysis-report-*.md` artifact in the workflow dir; "
                f"none found. T2 should fire only from `review-response.md` Step 10 "
                f"AFTER a review cycle produced its analysis report."
            )
    return None


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="metrics_collector")
    parser.add_argument("workflow_dir", help="Path to ai/<date>-<id>/")
    parser.add_argument(
        "--round",
        required=True,
        help="`0` (T1 PR creation) / `1..N` (T2 review round) / `final` (T3 reconcile)",
    )
    args = parser.parse_args(argv)

    workflow_dir = Path(args.workflow_dir).resolve()
    if not workflow_dir.is_dir():
        print(
            f"metrics_collector: workflow dir does not exist: {workflow_dir}",
            file=sys.stderr,
        )
        return 2

    tracker_path = _resolve_tracker(workflow_dir)
    if tracker_path is None:
        print(
            f"metrics_collector: no tracker (tracker.md / tracker.archived.md) "
            f"under {workflow_dir}",
            file=sys.stderr,
        )
        return 2

    work_item_id = workflow_dir.name.split("-", 3)[-1] if workflow_dir.name.count("-") >= 3 else workflow_dir.name

    text = tracker_path.read_text(encoding="utf-8")
    workflow_metrics = _parse_workflow_metrics(text)
    tasks = _parse_task_rows(text)
    mode = _extract_mode(text)

    err = _validate(workflow_metrics, tasks)
    if err:
        path = _write_error(workflow_dir, err)
        print(
            f"metrics_collector: validation failed — {err}; details at {path}",
            file=sys.stderr,
        )
        return 1

    # Precondition gate (CC-05.3 / CC-05.4): refuse to record a row when
    # the upstream phase hasn't published its exit signal. Prevents the
    # empty-aggregate phantom rows observed in the live HEX workspace at
    # `harness-2.0/ai/2026-05-22-US-023` where T1 + T2 fired before
    # `PR created` was stamped and before any analysis report existed.
    precondition_err = _check_round_preconditions(args.round, workflow_metrics, workflow_dir)
    if precondition_err:
        path = _write_error(workflow_dir, precondition_err)
        print(
            f"metrics_collector: precondition unmet — {precondition_err}; details at {path}",
            file=sys.stderr,
        )
        return 2

    aggregates = _compute_aggregates(workflow_metrics, tasks, workflow_dir, mode=mode)
    generated_at = _utc_now()

    report = _render_report(
        workflow_dir, work_item_id, args.round, workflow_metrics, tasks, aggregates, generated_at,
    )
    (workflow_dir / "metrics-report.md").write_text(report, encoding="utf-8")

    # CSV lives at the workspace level (one directory up from the
    # workflow dir's parent `ai/`). Walk up to the workspace root.
    ai_dir = workflow_dir.parent
    csv_path = ai_dir / METRICS_CSV_FILENAME
    _append_csv_row(csv_path, work_item_id, args.round, generated_at, aggregates)

    _stamp_tracker(tracker_path, args.round, generated_at)

    print(
        f"metrics_collector: wrote {workflow_dir / 'metrics-report.md'} + "
        f"appended row to {csv_path} (round={args.round})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

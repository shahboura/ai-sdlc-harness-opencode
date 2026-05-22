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
        "",
        "## Aggregates",
        "",
        "| Metric | Value |",
        "|---|---|",
    ]
    for k, v in aggregates.items():
        display = "—" if v is None else str(v)
        lines.append(f"| {k.replace('_', ' ')} | {display} |")
    lines.append("")
    lines.append("## Per-Task Summary")
    lines.append("")
    if tasks:
        lines.append("| Task | Status | Review Rounds | Started | Completed |")
        lines.append("|---|---|---|---|---|")
        for row in tasks:
            first_col = next(iter(row.values()), "?")
            lines.append(
                f"| {first_col} | {row.get('Status', '—')} | "
                f"{row.get('Review Rounds', '0')} | "
                f"{row.get('Started', '—')} | "
                f"{row.get('Completed', '—')} |"
            )
    else:
        lines.append("(no task rows parsed)")
    lines.append("")
    lines.append("## Token Usage")
    lines.append("")
    lines.append("| Field | Value |")
    lines.append("|---|---|")
    token_keys = [
        ("tokens_input", "Input tokens"),
        ("tokens_output", "Output tokens"),
        ("tokens_cache_read", "Cache read tokens"),
        ("tokens_cache_write", "Cache write tokens"),
    ]
    for agg_key, label in token_keys:
        raw = aggregates.get(agg_key, "")
        # CC-02.4.2 / ADR-002: empty string means the hook hasn't landed yet —
        # render "tokens unavailable" rather than "0" or blank.
        display = raw if raw != "" else "tokens unavailable"
        lines.append(f"| {label} | {display} |")
    lines.append("")
    lines.append("## Source Workflow Metrics")
    lines.append("")
    if workflow_metrics:
        for k, v in workflow_metrics.items():
            lines.append(f"- **{k}**: {v}")
    else:
        lines.append("(no workflow metrics parsed)")
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

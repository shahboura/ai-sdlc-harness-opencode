#!/usr/bin/env python3
"""metrics_collector — workflow metrics aggregator (IMPL-17-03).

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

Created by: dev-workflow-plan.md [M-17] [IMPL-17-03]
CC conventions applied: CC-01.5 (exit codes), CC-04.3, CC-05.7, CC-05.3.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

SCHEMA_VERSION = "1.0.0"
METRICS_CSV_FILENAME = "_metrics-log.csv"

# Canonical timestamp format per CC-05.3.
TS_FMT = "%Y-%m-%d %H:%M UTC"

# CSV columns per IMPL-17-04 schema.
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
    """Extract `Field: value` lines from the `## Workflow Metrics` section."""
    m = re.search(r"^##\s+Workflow Metrics\s*$", tracker_text, flags=re.MULTILINE)
    if not m:
        return {}
    body = tracker_text[m.end():]
    next_section = re.search(r"^##\s+\S", body, flags=re.MULTILINE)
    if next_section:
        body = body[: next_section.start()]
    out: Dict[str, str] = {}
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([A-Z][A-Za-z0-9 ()/_-]+?):\s*(.+?)\s*$", line)
        if m:
            out[m.group(1).strip()] = m.group(2).strip()
    return out


_TASK_ROW_RE = re.compile(r"^\|\s*(T[\w.-]+)\s*\|", re.MULTILINE)


def _parse_task_rows(tracker_text: str) -> List[Dict[str, str]]:
    """Parse the `## Tasks` table into a list of {col_name: value} dicts.

    The header row defines column names; subsequent `| T<n> | ... |` rows
    are parsed into per-task dicts.
    """
    m = re.search(r"^##\s+Tasks\s*$", tracker_text, flags=re.MULTILINE)
    if not m:
        return []
    body = tracker_text[m.end():]
    next_section = re.search(r"^##\s+\S", body, flags=re.MULTILINE)
    if next_section:
        body = body[: next_section.start()]
    lines = [line for line in body.splitlines() if line.strip().startswith("|")]
    if len(lines) < 2:
        return []
    # First | row is the header, second is the separator |---|---|.
    header_cells = [c.strip() for c in lines[0].strip().strip("|").split("|")]
    task_rows: List[Dict[str, str]] = []
    for line in lines[2:]:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != len(header_cells):
            continue
        row = dict(zip(header_cells, cells))
        first_col = next(iter(row.values()), "")
        if re.match(r"^T[\w.-]+$", first_col):
            task_rows.append(row)
    return task_rows


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

    return {
        "cycle_time_minutes": _minutes_between(plan_approved, pr_created),
        "p3_duration_minutes": _minutes_between(dev_started, dev_completed),
        "p5_duration_minutes": _minutes_between(th_started, th_completed),
        "p7_duration_minutes": _minutes_between(pr_created, pr_resp_completed),
        "reviewer_rework_rounds": _sum_review_rounds(tasks),
        "pr_review_rounds": _count_pr_review_rounds(workflow_dir),
        "coverage_pct": _extract_coverage(workflow_metrics),
        "defect_escape_count": _count_defect_escapes(workflow_dir),
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
    new_file = not csv_path.exists()
    row = {
        "schema_version": SCHEMA_VERSION,
        "work_item_id": work_item_id,
        "round": round_label,
        "timestamp_utc": generated_at,
    }
    for key in CSV_COLUMNS:
        if key in row:
            continue
        v = aggregates.get(key)
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

    err = _validate(workflow_metrics, tasks)
    if err:
        path = _write_error(workflow_dir, err)
        print(
            f"metrics_collector: validation failed — {err}; details at {path}",
            file=sys.stderr,
        )
        return 1

    aggregates = _compute_aggregates(workflow_metrics, tasks, workflow_dir)
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

#!/usr/bin/env python3
"""markdown-size-report.py — Plugin-tree markdown size report (IMPL-26-02).

Walks the plugin tree, classifies every *.md file using the same tier
definitions as cc-check-md-budget.py (CC-04.8), and emits a sorted
markdown table showing file, tier, lines, bytes, and budget status.

Usage:
    python3 scripts/markdown-size-report.py [<repo_root>]
    python3 scripts/markdown-size-report.py [<repo_root>] --format table|csv

Exit codes:
    0   report emitted successfully
    1   repo_root not found or I/O error

Output columns:
    file     — path relative to repo root
    tier     — CLAUDE.md | SKILL.md | command | agent-prompt | context | —
    lines    — number of lines
    bytes    — file size in bytes
    status   — OK | WARN-soft | WARN-hard | EXEMPT | EXEMPT-INVALID

Table is sorted by lines descending so the largest files appear first.
Runtime target: ≤ 2 seconds on the full plugin tree (TEST-195, NFR-2 stdlib only).

Created by: dev-workflow-plan.md [M-26] [IMPL-26-02]
CC conventions applied: CC-04.8, CC-08 (reuses cc-check-md-budget classifier).
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import sys
from pathlib import Path
from typing import List, Optional

# ---------------------------------------------------------------------------
# Import classifier from cc-check-md-budget.py (hyphenated — use importlib)
# ---------------------------------------------------------------------------

def _load_budget_module():
    scripts_dir = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(
        "cc_check_md_budget",
        scripts_dir / "cc-check-md-budget.py",
    )
    if spec is None or spec.loader is None:
        raise ImportError("Cannot locate cc-check-md-budget.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["cc_check_md_budget"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


# ---------------------------------------------------------------------------
# Status labels (superset of CC-04.8 Finding.severity)
# ---------------------------------------------------------------------------

_STATUS_ORDER = {
    "EXEMPT-INVALID": 0,
    "HARD-CAP":       1,
    "SOFT-CEIL":      2,
    "EXEMPT":         3,
    "OK":             4,
}

_STATUS_DISPLAY = {
    "OK":             "OK",
    "SOFT-CEIL":      "WARN-soft",
    "HARD-CAP":       "WARN-hard",
    "EXEMPT":         "EXEMPT",
    "EXEMPT-INVALID": "EXEMPT-INVALID",
}

# ---------------------------------------------------------------------------
# Table renderer
# ---------------------------------------------------------------------------

def _render_table(findings, repo: Path) -> str:
    """Render a markdown table sorted by lines descending."""
    # Sort: non-OK first by status severity, then by lines descending
    def sort_key(f):
        return (_STATUS_ORDER.get(f.severity, 9), -f.lines)

    rows = sorted(findings, key=sort_key)

    header = "| file | tier | lines | bytes | status |"
    sep    = "|---|---|---:|---:|---|"
    lines_out = [header, sep]

    for f in rows:
        try:
            size = (repo / f.rel).stat().st_size
        except OSError:
            size = 0
        status_display = _STATUS_DISPLAY.get(f.severity, f.severity)
        lines_out.append(
            f"| `{f.rel}` | {f.tier} | {f.lines:,} | {size:,} | {status_display} |"
        )

    return "\n".join(lines_out)


def _render_csv(findings, repo: Path) -> str:
    """Render CSV output (file,tier,lines,bytes,status)."""
    rows = ["file,tier,lines,bytes,status"]
    for f in sorted(findings, key=lambda x: -x.lines):
        try:
            size = (repo / f.rel).stat().st_size
        except OSError:
            size = 0
        status_display = _STATUS_DISPLAY.get(f.severity, f.severity)
        rows.append(f"{f.rel},{f.tier},{f.lines},{size},{status_display}")
    return "\n".join(rows)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    parser = argparse.ArgumentParser(
        description="Emit a markdown size report for the plugin tree (CC-04.8)"
    )
    parser.add_argument(
        "repo_root",
        nargs="?",
        default=".",
        help="Repository root directory (default: current directory)",
    )
    parser.add_argument(
        "--format",
        choices=["table", "csv"],
        default="table",
        help="Output format: markdown table (default) or CSV",
    )
    args = parser.parse_args(argv)

    repo = Path(args.repo_root).resolve()
    if not repo.is_dir():
        print(f"markdown-size-report: repo_root not found: {repo}", file=sys.stderr)
        return 1

    try:
        budget_mod = _load_budget_module()
    except ImportError as e:
        print(f"markdown-size-report: {e}", file=sys.stderr)
        return 1

    # Use cc-check-md-budget's scan() in warn mode (we only need findings)
    findings = budget_mod.scan(repo, mode="warn")

    # Summary line
    ok_count    = sum(1 for f in findings if f.severity == "OK")
    warn_soft   = sum(1 for f in findings if f.severity == "SOFT-CEIL")
    warn_hard   = sum(1 for f in findings if f.severity == "HARD-CAP")
    exempt      = sum(1 for f in findings if f.severity == "EXEMPT")
    invalid     = sum(1 for f in findings if f.severity == "EXEMPT-INVALID")
    total       = len(findings)

    print(f"# Markdown Size Report\n")
    print(f"> Generated from `{repo.name}/` — {total} classified files")
    print(f"> OK: {ok_count} · WARN-soft: {warn_soft} · WARN-hard: {warn_hard} · EXEMPT: {exempt} · INVALID: {invalid}\n")

    if args.format == "csv":
        print(_render_csv(findings, repo))
    else:
        print(_render_table(findings, repo))

    return 0


if __name__ == "__main__":
    sys.exit(main())

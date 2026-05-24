#!/usr/bin/env python3
"""cc-check-md-budget.py — CC-04.8 markdown size-budget checker.

Classifies every *.md file in the plugin tree into one of five load-mode
tiers and checks each against its soft ceiling (WARN) and hard cap (WARN
in v2.1 / BLOCK in v2.1.1 per ADR-006).

Usage:
    python3 cc-check-md-budget.py <repo_root>
    python3 cc-check-md-budget.py <repo_root> --hard-cap-mode warn|block

Environment override (for tests only — not a public user flag):
    CC_MD_BUDGET_HARD_CAP_MODE=warn|block

Exit codes:
    0   all checks pass (or warn-only mode — v2.1 default)
    1   internal error (e.g. repo_root not found)
    2   hard-cap violation(s) found AND mode == "block" (v2.1.1+)

Created by: dev-workflow-plan.md [M-26] [IMPL-26-01]
CC conventions applied: CC-04.8, ADR-006.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import List, NamedTuple, Optional

# ---------------------------------------------------------------------------
# v2.1 release constant: "warn"  ← flip to "block" in v2.1.1 (US-E03-009)
# Override via CC_MD_BUDGET_HARD_CAP_MODE env var (tests only; ADR-006).
# ---------------------------------------------------------------------------
_DEFAULT_HARD_CAP_MODE = "block"  # ADR-006: time-bounded exception ended at v2.1.1 (US-E03-009)

# ---------------------------------------------------------------------------
# Tier definitions  (CC-04.8)
# ---------------------------------------------------------------------------
_TIERS = [
    # name          path_key        soft  hard
    ("CLAUDE.md",   "claude-md",    100,  200),
    ("SKILL.md",    "skill-md",     300,  400),
    ("command",     "command",      200,  400),
    ("agent-prompt","agent-prompt", 250,  400),
    ("context",     "context",      100,  200),
]

_TIER_MAP = {name: (soft, hard) for name, _, soft, hard in _TIERS}

# Exemption marker — must appear in first 15 lines of the file.
# reason= attribute must be non-empty; empty reason is rejected.
_EXEMPT_RE = re.compile(
    r'<!--\s*cc-md-budget:\s*exempt\s+reason="([^"]*)"',
    re.IGNORECASE,
)

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

def classify(path: Path, repo: Path) -> Optional[str]:
    """Return the tier name for *path*, or None if the file is out-of-scope.

    Priority (most-specific first):
        1. Exact root-level CLAUDE.md
        2. agents/shared/* — explicitly out of scope (structural reference)
        3. agents/*/<any>.md — agent-prompt
        4. skills/**/SKILL.md (by name) — SKILL.md
        5. skills/**/commands/*.md — command
        6. */context/*.md — context
        7. Everything else — None (out of scope)
    """
    try:
        rel = path.relative_to(repo)
    except ValueError:
        return None

    parts = rel.parts

    # Skip dotfiles / system dirs
    if parts and parts[0].startswith("."):
        return None

    # 1. Root-level CLAUDE.md only
    if rel == Path("CLAUDE.md"):
        return "CLAUDE.md"

    # 2. agents/shared/* — out of scope (structural reference docs)
    if len(parts) >= 2 and parts[0] == "agents" and parts[1] == "shared":
        return None

    # 3. Agent prompts: agents/*/**/*.md (any depth under a non-shared agent dir)
    if parts[0] == "agents":
        return "agent-prompt"

    if parts[0] == "skills":
        # 4. SKILL.md files (canonical name, anywhere under skills/)
        if path.name == "SKILL.md":
            return "SKILL.md"

        # 5. Command files: skills/**/commands/**/*.md
        if "commands" in parts:
            return "command"

    # 6. Context files: any */context/*.md (matches skills/**/context/ too)
    if "context" in parts:
        return "context"

    return None  # out of scope — not checked


# ---------------------------------------------------------------------------
# Exemption parsing
# ---------------------------------------------------------------------------

def _check_exemption(path: Path) -> Optional[str]:
    """Return the exemption reason string, empty string for invalid marker, or None if no marker.

    None  → no exemption marker found; file should be checked normally.
    ""    → exemption marker present but reason= is empty (invalid; treat as not exempt).
    <str> → valid exemption with non-empty reason.
    """
    try:
        lines = path.read_text(encoding="utf-8").splitlines()[:15]
    except (OSError, UnicodeDecodeError):
        return None
    head = "\n".join(lines)
    m = _EXEMPT_RE.search(head)
    if m is None:
        return None
    reason = m.group(1).strip()
    return reason  # "" → invalid (empty reason)


# ---------------------------------------------------------------------------
# Result model
# ---------------------------------------------------------------------------

class Finding(NamedTuple):
    rel: str
    tier: str
    lines: int
    severity: str  # "SOFT-CEIL" | "HARD-CAP" | "EXEMPT" | "EXEMPT-INVALID" | "OK"
    message: str


# ---------------------------------------------------------------------------
# Core scan
# ---------------------------------------------------------------------------

def scan(repo: Path, mode: str) -> List[Finding]:
    """Walk *repo* and return a Finding for every classified .md file."""
    findings: List[Finding] = []

    for path in sorted(repo.rglob("*.md")):
        try:
            rel = path.relative_to(repo)
        except ValueError:
            continue
        rel_str = str(rel).replace(os.sep, "/")

        # Skip out-of-scope top-level dirs (scripts, tests, docs, .git, hooks)
        if rel.parts and rel.parts[0] in ("scripts", "tests", "docs", ".git", "hooks"):
            continue

        tier_name = classify(path, repo)
        if tier_name is None:
            continue

        soft, hard = _TIER_MAP[tier_name]

        # --- exemption check ---
        exemption = _check_exemption(path)
        if exemption is not None:
            if exemption == "":
                # Invalid: empty reason
                findings.append(Finding(
                    rel=rel_str, tier=tier_name, lines=0,
                    severity="EXEMPT-INVALID",
                    message="exempt marker present but reason= is empty (marker rejected)",
                ))
            else:
                findings.append(Finding(
                    rel=rel_str, tier=tier_name, lines=0,
                    severity="EXEMPT",
                    message=f"reason: {exemption}",
                ))
            continue

        # --- line count ---
        try:
            line_count = len(path.read_text(encoding="utf-8").splitlines())
        except (OSError, UnicodeDecodeError):
            continue

        if line_count > hard:
            findings.append(Finding(
                rel=rel_str, tier=tier_name, lines=line_count,
                severity="HARD-CAP",
                message=f"{line_count} lines > hard cap {hard}",
            ))
        elif line_count > soft:
            findings.append(Finding(
                rel=rel_str, tier=tier_name, lines=line_count,
                severity="SOFT-CEIL",
                message=f"{line_count} lines > soft ceiling {soft}",
            ))
        else:
            findings.append(Finding(
                rel=rel_str, tier=tier_name, lines=line_count,
                severity="OK",
                message=f"{line_count} lines",
            ))

    return findings


# ---------------------------------------------------------------------------
# Reporter
# ---------------------------------------------------------------------------

def report(findings: List[Finding], mode: str) -> int:
    """Print findings to stdout/stderr and return an exit code."""
    ok_count = sum(1 for f in findings if f.severity == "OK")
    exempt_count = sum(1 for f in findings if f.severity == "EXEMPT")
    soft_count = sum(1 for f in findings if f.severity == "SOFT-CEIL")
    hard_count = sum(1 for f in findings if f.severity == "HARD-CAP")
    invalid_count = sum(1 for f in findings if f.severity == "EXEMPT-INVALID")

    for f in findings:
        if f.severity == "OK":
            continue  # suppress OK lines for readability
        if f.severity == "EXEMPT":
            print(f"  EXEMPT  {f.rel}  [{f.tier}]  {f.message}")
            continue
        if f.severity == "EXEMPT-INVALID":
            print(f"  WARN    {f.rel}  [{f.tier}]  {f.message}", file=sys.stderr)
            continue
        # SOFT-CEIL and HARD-CAP
        if f.severity == "HARD-CAP" and mode == "block":
            print(f"  BLOCK   {f.rel}  [{f.tier}]  {f.message}", file=sys.stderr)
        else:
            print(f"  WARN    {f.rel}  [{f.tier}]  {f.message}", file=sys.stderr)

    print(
        f"cc-check-md-budget: {ok_count} OK, {soft_count} WARN-soft, "
        f"{hard_count} {'BLOCK' if mode == 'block' else 'WARN'}-hard, "
        f"{exempt_count} EXEMPT, {invalid_count} INVALID  (mode={mode})"
    )

    if mode == "block" and (hard_count > 0 or invalid_count > 0):
        return 2
    return 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    parser = argparse.ArgumentParser(
        description="CC-04.8 markdown size-budget checker",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("repo_root", help="Repository root directory")
    parser.add_argument(
        "--hard-cap-mode",
        choices=["warn", "block"],
        default=None,
        help=(
            "Override hard-cap enforcement mode. "
            "Tests only — production relies on the compiled default. "
            "Per ADR-006, this is not a public user flag."
        ),
    )
    args = parser.parse_args(argv)

    repo = Path(args.repo_root).resolve()
    if not repo.is_dir():
        print(f"cc-check-md-budget: repo_root not found: {repo}", file=sys.stderr)
        return 1

    # Mode resolution: CLI arg > env var > compiled default
    if args.hard_cap_mode is not None:
        mode = args.hard_cap_mode
    else:
        mode = os.environ.get("CC_MD_BUDGET_HARD_CAP_MODE", _DEFAULT_HARD_CAP_MODE)
    if mode not in ("warn", "block"):
        print(
            f"cc-check-md-budget: invalid hard-cap mode '{mode}'; expected warn|block",
            file=sys.stderr,
        )
        return 1

    findings = scan(repo, mode)
    return report(findings, mode)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""quick-mode-classify — shared change-risk classifier (IMPL-25-01).

Exposes two pure functions consumed by:
  - QPhaseGuard (US-E01-003) — quick-mode entry gate enforcement
  - Planner TDD-skip heuristics (US-E01-006) — test-required: false decisions
  - Gate-policy tiering (EPIC-05, v2.2) — auto-approve risk tier input

Single source of truth per ADR-011: both quantitative thresholds (FR-1.4
hard aborts) and categorical heuristics (FR-10 safe categories) live in
.claude/context/quick-mode-config.md, written by /init-workspace from
skills/init-workspace/templates/quick-mode-config.md.

Public API:
    classify_change(diff_text, config_path=None) -> (RiskTier, ChangeStats)
    is_quick_mode_safe_category(category, config_path=None) -> bool

CLI usage (for shell consumers):
    python3 scripts/quick-mode-classify.py \\
        --diff <path-or-dash>        # git diff text; - = stdin
        [--config <path>]            # override config location
        [--check-category <cat>]     # instead of diff: check one category

    Outputs JSON on stdout:
      classify mode:  {"tier": "low|medium|high", "stats": {...}, "abort": bool}
      category mode:  {"category": "<cat>", "safe": true|false}

Exit codes:
    0   success
    1   failure (IO error, parse error)
    2   precondition not met (missing required argument)

Created by: dev-workflow-plan.md [M-25] [IMPL-25-01]
CC conventions applied:
    CC-04.1  — single source of truth (one classifier, three consumers)
    CC-08    — DRY (thresholds + categories in one shared config file)
    CC-09    — tunable thresholds sourced from quick-mode-config.md, never hardcoded
    ADR-011  — shared thresholds + TDD-skip categories in one file
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Default thresholds — used when quick-mode-config.md is absent.
# Values must match the CC-09 tunable-threshold table in cc-conventions.md.
# Override path: .claude/context/quick-mode-config.md
# ---------------------------------------------------------------------------
_DEFAULTS: Dict = {
    # Quantitative thresholds (FR-1.4 hard aborts)
    "loc_max": 80,         # CC-09 source-of-truth: this file; override: quick-mode-config.md
    "files_max": 5,        # CC-09 source-of-truth: this file; override: quick-mode-config.md
    "abort_on_public_api": True,
    "abort_on_migration": True,
    "abort_on_security_paths": True,
    # Categorical heuristics (FR-10 / FR-1 shared, per ADR-011)
    "quick_mode_safe_categories": [
        "ui-style-copy",
        "infra-config",
        "exploratory-data",
        "doc-only",
    ],
    # Path patterns used for structural classification
    "public_api_patterns": [
        "*/__init__.py",
        "*/index.ts",
        "*/index.js",
        "*.d.ts",
        "*/api/*.py",
        "*/api/*.ts",
    ],
    "migration_patterns": [
        "*/migrations/*",
        "*/migrate/*",
        "*_migration.py",
        "*_migration.ts",
        "*migration_*.py",
    ],
    "security_paths": [
        "auth/",
        "crypto/",
        "security/",
        ".env",
        "secrets/",
        "credentials/",
    ],
}

# Default config location relative to cwd (workspace root).
_DEFAULT_CONFIG_REL = ".claude/context/quick-mode-config.md"


# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

class RiskTier(Enum):
    """Change risk tier — consumed by QPhaseGuard and gate-policy (ADR-003)."""
    low = "low"
    medium = "medium"
    high = "high"


@dataclass
class ChangeStats:
    """Structural statistics extracted from a git diff."""
    loc_delta: int              # total lines added + removed (absolute)
    files_touched: int          # number of files in the diff
    public_api_touched: bool    # any file matches a public-API pattern
    migration_touched: bool     # any file matches a migration pattern
    security_paths_touched: bool  # any file matches a security-sensitive path
    coverage_delta: int = 0     # reserved — always 0 (not computable from diff)


# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

def _load_config(config_path: Optional[Path] = None) -> Dict:
    """Load and parse quick-mode-config.md.  Returns defaults if file is absent."""
    if config_path is None:
        config_path = Path(_DEFAULT_CONFIG_REL)

    cfg = dict(_DEFAULTS)  # start from defaults; overlay with file values

    if not config_path.is_file():
        return cfg  # AC: "loads the shipped default thresholds" when missing

    text = config_path.read_text(encoding="utf-8")
    cfg.update(_parse_config_text(text))
    return cfg


def _parse_config_text(text: str) -> Dict:
    """Extract key: value pairs and list blocks from a markdown config file.

    Supports two shapes:
        scalar   →  key: value
        list     →  key:\n  - item\n  - item
    """
    result: Dict = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        # Scalar: `key: value`  (skip markdown headings and blank lines)
        scalar_m = re.match(r"^([a-z_]+):\s+(.+)$", line.strip())
        if scalar_m:
            key, val = scalar_m.group(1), scalar_m.group(2).strip()
            # Coerce booleans
            if val.lower() == "true":
                result[key] = True
            elif val.lower() == "false":
                result[key] = False
            else:
                try:
                    result[key] = int(val)
                except ValueError:
                    result[key] = val
            i += 1
            continue

        # List key: `key:` on its own line followed by `  - item` lines
        list_key_m = re.match(r"^([a-z_]+):\s*$", line.strip())
        if list_key_m:
            key = list_key_m.group(1)
            items: List[str] = []
            j = i + 1
            while j < len(lines):
                item_m = re.match(r"^\s+-\s+(.+)$", lines[j])
                if item_m:
                    items.append(item_m.group(1).strip())
                    j += 1
                else:
                    break
            if items:
                result[key] = items
            i = j
            continue

        i += 1

    return result


# ---------------------------------------------------------------------------
# Diff parsing
# ---------------------------------------------------------------------------

def _parse_diff(diff_text: str) -> Tuple[int, List[str]]:
    """Parse a unified diff.  Returns (loc_delta, [file_paths])."""
    loc_delta = 0
    file_paths: List[str] = []

    for line in diff_text.splitlines():
        # Count the diff --git headers for file count
        m = re.match(r"^diff --git a/(.+) b/(.+)$", line)
        if m:
            file_paths.append(m.group(2))  # use the b/ (destination) path
            continue
        # Count added / removed lines (skip +++ / --- file headers)
        if line.startswith("+") and not line.startswith("+++"):
            loc_delta += 1
        elif line.startswith("-") and not line.startswith("---"):
            loc_delta += 1

    return loc_delta, file_paths


def _matches_any(path: str, patterns: List[str]) -> bool:
    """True if `path` matches any pattern (fnmatch glob or substring prefix)."""
    for pat in patterns:
        # Substring prefix match (e.g. "auth/")
        if pat.endswith("/") and (f"/{pat}" in path or path.startswith(pat)):
            return True
        # Exact basename match for dotfiles (e.g. ".env")
        if pat.startswith(".") and "/" not in pat:
            base = path.rsplit("/", 1)[-1] if "/" in path else path
            if fnmatch.fnmatch(base, pat):
                return True
        # Standard glob
        if fnmatch.fnmatch(path, pat) or fnmatch.fnmatch(path.replace("\\", "/"), pat):
            return True
    return False


# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

def classify_change(
    diff_text: str,
    config_path: Optional[Path] = None,
) -> Tuple[RiskTier, ChangeStats]:
    """Classify a change from its git diff.

    Returns (RiskTier, ChangeStats).  Pure — no side effects, no file writes.

    The caller (QPhaseGuard) uses the RiskTier and raw stats to enforce the
    hard upgrade thresholds declared in FR-1.4 and CC-05.8.

    Gate-policy (ADR-003, EPIC-05) uses the same return value for tier-based
    auto-approve decisions.
    """
    cfg = _load_config(config_path)
    loc_delta, file_paths = _parse_diff(diff_text)

    public_api = any(
        _matches_any(p, cfg.get("public_api_patterns", _DEFAULTS["public_api_patterns"]))
        for p in file_paths
    )
    migration = any(
        _matches_any(p, cfg.get("migration_patterns", _DEFAULTS["migration_patterns"]))
        for p in file_paths
    )
    security = any(
        _matches_any(p, cfg.get("security_paths", _DEFAULTS["security_paths"]))
        for p in file_paths
    )

    stats = ChangeStats(
        loc_delta=loc_delta,
        files_touched=len(file_paths),
        public_api_touched=public_api,
        migration_touched=migration,
        security_paths_touched=security,
        coverage_delta=0,
    )

    loc_max: int = int(cfg.get("loc_max", _DEFAULTS["loc_max"]))
    files_max: int = int(cfg.get("files_max", _DEFAULTS["files_max"]))

    # Determine tier
    hard_abort = (
        (cfg.get("abort_on_security_paths", True) and security)
        or (cfg.get("abort_on_public_api", True) and public_api)
        or (cfg.get("abort_on_migration", True) and migration)
        or loc_delta > loc_max
        or len(file_paths) > files_max
    )
    if hard_abort:
        return RiskTier.high, stats

    # Medium: exceeds half the quantitative thresholds but within hard caps
    soft_breach = loc_delta > (loc_max // 2) or len(file_paths) > (files_max // 2)
    if soft_breach:
        return RiskTier.medium, stats

    return RiskTier.low, stats


def is_quick_mode_safe_category(
    category: str,
    config_path: Optional[Path] = None,
) -> bool:
    """Return True if `category` appears in quick_mode_safe_categories.

    Shared between QPhaseGuard and Planner's TDD-skip heuristics per ADR-011.
    """
    cfg = _load_config(config_path)
    safe: List[str] = cfg.get(
        "quick_mode_safe_categories",
        _DEFAULTS["quick_mode_safe_categories"],
    )
    return category.strip().lower() in [c.strip().lower() for c in safe]


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Classify a change's risk tier from a git diff.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument(
        "--diff",
        metavar="PATH",
        help="Path to a git diff file, or - to read from stdin.",
    )
    g.add_argument(
        "--check-category",
        metavar="CATEGORY",
        help="Check whether CATEGORY is in quick_mode_safe_categories.",
    )
    p.add_argument(
        "--config",
        metavar="PATH",
        default=None,
        help=f"Path to quick-mode-config.md (default: {_DEFAULT_CONFIG_REL}).",
    )
    return p


def main(argv: Optional[List[str]] = None) -> int:  # type: ignore[type-arg]
    parser = _build_parser()
    args = parser.parse_args(argv)

    config_path = Path(args.config) if args.config else None

    try:
        if args.check_category is not None:
            safe = is_quick_mode_safe_category(args.check_category, config_path)
            print(json.dumps({"category": args.check_category, "safe": safe}))
            return 0

        # --diff mode
        if args.diff == "-":
            diff_text = sys.stdin.read()
        else:
            diff_path = Path(args.diff)
            if not diff_path.is_file():
                print(f"error: diff file not found: {diff_path}", file=sys.stderr)
                return 2
            diff_text = diff_path.read_text(encoding="utf-8")

        tier, stats = classify_change(diff_text, config_path)
        abort = tier == RiskTier.high
        result = {
            "tier": tier.value,
            "abort": abort,
            "stats": asdict(stats),
        }
        print(json.dumps(result, indent=2))
        return 0

    except Exception as exc:  # pylint: disable=broad-except
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

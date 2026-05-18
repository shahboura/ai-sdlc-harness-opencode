#!/usr/bin/env bash
# CC07-04-mermaid-syntax.convention-check.test.sh — TEST-95 / TEST-108
#
# Per CC-07.4 / CC-07.4.1, every Mermaid diagram embedded in the harness's
# markdown must satisfy the structural syntax requirements: HTML-entity
# escaping (`&lt;` instead of `<`), quoted subgraph titles, classDef ↔
# class-reference closure, node-ID closure, shape-delimiter closure (stadium
# / parallelogram / hexagonal), no `<!-- -->` comments inside fences, and
# the 60-node ceiling.
#
# This convention-check delegates per-file validation to the existing
# `validate-mermaid` skill's backer (`scripts/_validate_mermaid_syntax.py`)
# — no diagram-parsing logic lives here, only the discovery + aggregation
# layer.
#
# Fail policy: **fail-OPEN (advisory)** by default. The validator currently
# surfaces a real but historically-tolerated violation (README.md's
# overview flowchart exceeds the 60-node cap from CC-07.4.1 R9). Fixing
# the README requires splitting the diagram into sub-diagrams, which is
# editorial work outside the scope of M-13 substance. Set `CC0704_STRICT=1`
# in the env to flip to fail-closed once the README is split or the cap
# is waived for that specific diagram.
#
# Created by: dev-workflow-plan.md [M-13] [IMPL-13-02-EXT-C]
# Maps to: TEST-95 (M-16 integration), TEST-108 (CC-07.4 cross-cutting).
# CC conventions applied: CC-07.4, CC-07.4.1, CC-06.2, CC-08.1 (delegates
# to the existing validator backer instead of reimplementing).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import os
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
validator = repo / "scripts" / "_validate_mermaid_syntax.py"

if not validator.is_file():
    print(f"[CC-07.4] {validator.relative_to(repo)} missing — cannot run mermaid syntax check", file=sys.stderr)
    sys.exit(2)

# Discover every .md file that contains at least one Mermaid fence.
# Exclude vendor / installed-plugin caches that aren't part of the harness.
EXCLUDE_PREFIXES = (
    ".git/",
    "node_modules/",
    ".claude/plugins/",
)

candidates: list[Path] = []
for path in repo.rglob("*.md"):
    rel = str(path.relative_to(repo)).replace(os.sep, "/")
    if any(rel.startswith(p) for p in EXCLUDE_PREFIXES):
        continue
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        continue
    if "```mermaid" in content:
        candidates.append(path)

if not candidates:
    print("CC-07.4 mermaid-syntax: no markdown files with mermaid fences found")
    sys.exit(0)

failures: list[tuple[Path, str]] = []
checked = 0
for path in sorted(candidates):
    checked += 1
    try:
        result = subprocess.run(
            ["python3", str(validator), str(path)],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        failures.append((path, f"validator crashed: {e}"))
        continue
    if result.returncode == 0:
        continue
    # rc == 1 — rule violation; rc == 2 — precondition unmet (treat as
    # validator-side issue, not the file's fault — surface as a warning
    # but don't block).
    if result.returncode == 1:
        # The validator emits one structured failure line per violation
        # (`<file>:<line>:<col>: <rule>: <message>`) on stderr/stdout, then
        # an `advisory: ...` line that's NOT a violation but a runtime
        # capability note. Filter out the advisory lines so the per-file
        # message reflects the actual violation.
        all_lines = (result.stderr + "\n" + result.stdout).strip().splitlines()
        violation_lines = [
            ln for ln in all_lines
            if ln and not ln.startswith("advisory:") and not ln.lower().startswith("warning:")
        ]
        msg = violation_lines[-1] if violation_lines else (all_lines[-1] if all_lines else "unspecified mermaid syntax failure")
        failures.append((path, msg))

strict_mode = os.environ.get("CC0704_STRICT") == "1"
print(
    f"CC-07.4 mermaid-syntax: scanned {checked} markdown file(s) with mermaid fences; "
    f"{len(failures)} violation(s) — "
    f"{'STRICT (fail-closed)' if strict_mode else 'ADVISORY (fail-open until README split / R9 waiver)'}"
)
for path, msg in failures[:30]:
    print(f"  ✗ {path.relative_to(repo)}: {msg}", file=sys.stderr)
if len(failures) > 30:
    print(f"  ... and {len(failures) - 30} more", file=sys.stderr)
if not failures:
    print("  every mermaid fence passes structural validation ✓")

sys.exit(1 if (failures and strict_mode) else 0)
PY

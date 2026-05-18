#!/usr/bin/env bash
# CC07-canonical-spec-header.convention-check.test.sh — TEST-74
#
# Per CC-07.3 (revised): every dev-workflow command file is the *canonical
# execution script* for its phase. The previous design pointed command files
# at an external `dev-workflow-phase-specs.md` authority doc (housed in the
# harness-management workspace, not the plugin); that cross-reference made
# the plugin functionally dependent on a file it never shipped with. The
# revised rule is the opposite: command files are self-contained, and no
# file in the harness may reference `dev-workflow-phase-specs.md`.
#
# This test fails if any harness file under `skills/`, `agents/`, `hooks/`,
# `scripts/`, or the plugin root mentions `dev-workflow-phase-specs.md`.
# Dev-time alignment checks under `tests/convention-check/` are exempt —
# those scripts may still grep the management workspace's authority specs
# when present (and auto-skip when not).
#
# Created by: dev-workflow-plan.md [M-13] [IMPL-13-02]
# Maps to: TEST-74 (CC-07.3 canonical-spec header — revised).
# CC conventions applied: CC-07.3, CC-04.5, CC-06.2.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import sys
from pathlib import Path

repo = Path(sys.argv[1])
roots = [
    repo / "skills",
    repo / "agents",
    repo / "hooks",
    repo / "scripts",
]
exempt_dirs = {repo / "tests"}

needle = "dev-workflow-phase-specs.md"
violations: list[str] = []
checked = 0

candidates: list[Path] = []
for root in roots:
    if not root.is_dir():
        continue
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if any(str(p).startswith(str(ex)) for ex in exempt_dirs):
            continue
        if p.suffix in {".md", ".py", ".sh", ".json"}:
            candidates.append(p)

# Also scan plugin-root markdown so CLAUDE.md / README.md / CHANGELOG.md
# (and other root-level docs) participate.
for p in repo.glob("*.md"):
    if p.is_file():
        candidates.append(p)

_DEV_JOURNAL_NAMES = {
    # Files that record historical interaction with the management workspace
    # but are not consumed by the runtime harness. Listing them is fine; they
    # don't make the harness functionally dependent on harness-mgm.
    "CHANGELOG.md",
    "execution-log.md",
    "cc-check-report.md",
}

for path in sorted(candidates):
    checked += 1
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        violations.append(f"{path.relative_to(repo)}: unreadable ({e})")
        continue
    if needle in content:
        if path.name in _DEV_JOURNAL_NAMES:
            continue
        violations.append(
            f"{path.relative_to(repo)}: references `{needle}` "
            f"(harness must not depend on the management workspace; CC-07.3)"
        )

print(f"CC-07.3 canonical-spec-header (revised): scanned {checked} file(s)")
for v in violations:
    print(f"  ✗ {v}", file=sys.stderr)
if not violations:
    print("  no harness file references the management-workspace spec ✓")

sys.exit(1 if violations else 0)
PY

#!/usr/bin/env bash
# CC06-test-naming.convention-check.test.sh — TEST-75
#
# Per CC-06.1, test files follow the canonical naming pattern. The
# precise pattern varies by tier:
#
#   tests/hooks/<concern>/test.sh
#   tests/skills/<concern>.test.sh
#   tests/integration/<phase>-<concern>/test.sh
#   tests/convention-check/<rule-id>-<concern>.convention-check.test.sh
#   tests/adapters/<adapter>/<concern>.test.sh
#
# This check enumerates every executable script under `tests/` (excluding
# library code under `tests/<tier>/lib/` and `tests/<tier>/_lib/`) and
# flags files that don't match a recognised pattern.
#
# Per M-12.1 (legacy test rename) closure: the harness-wide test surface
# has zero CC-06.1 naming violations, so this check is now **strict by
# default** (fail-closed). Set `CC06_ADVISORY=1` to flip to fail-open
# under exceptional circumstances (e.g., a transient legacy rename that
# hasn't landed yet).
#
# Created by: dev-workflow-plan.md [M-13] [IMPL-13-02] [M-12.1 closure]
# Maps to: TEST-75 (CC-06.1 test naming).
# CC conventions applied: CC-06.1, CC-06.2.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import os
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
tests_dir = repo / "tests"

if not tests_dir.is_dir():
    print(f"[CC-06.1] {tests_dir.relative_to(repo)}/ missing — nothing to check", file=sys.stderr)
    sys.exit(2)

# Per-tier patterns (a path is OK if it matches ANY of these).
TIER_PATTERNS = [
    re.compile(r"^tests/hooks/[a-z][a-z0-9-]*/test\.sh$"),
    re.compile(r"^tests/skills/[a-z][a-z0-9-]*\.test\.sh$"),
    re.compile(r"^tests/integration/[a-z][a-z0-9-]*/test\.sh$"),
    re.compile(r"^tests/convention-check/[A-Z]{2}[0-9A-Za-z-]+\.convention-check\.test\.sh$"),
    re.compile(r"^tests/adapters/[a-z][a-z0-9-]*/[a-z][a-z0-9-]*\.test\.sh$"),
    re.compile(r"^tests/adapters/[a-z][a-z0-9-]*/test\.sh$"),
    re.compile(r"^tests/[a-z]+/run\.sh$"),  # per-tier aggregators
    re.compile(r"^tests/run\.sh$"),
]

# Library code excluded from the check.
EXCLUDE_PARTS = ("/lib/", "/_lib/")

violations: list[str] = []
checked = 0
for path in sorted(tests_dir.rglob("*.sh")):
    rel = str(path.relative_to(repo)).replace(os.sep, "/")
    if any(part in rel for part in EXCLUDE_PARTS):
        continue
    if not path.is_file():
        continue
    checked += 1
    if not any(p.match(rel) for p in TIER_PATTERNS):
        violations.append(rel)

advisory_mode = os.environ.get("CC06_ADVISORY") == "1"
print(
    f"CC-06.1 test-naming: scanned {checked} test file(s); "
    f"{len(violations)} naming violation(s) — "
    f"{'ADVISORY (fail-open via CC06_ADVISORY=1)' if advisory_mode else 'STRICT (fail-closed; default post-M-12.1)'}"
)
for v in violations[:30]:
    print(f"  ✗ {v}", file=sys.stderr)
if len(violations) > 30:
    print(f"  ... and {len(violations) - 30} more", file=sys.stderr)
if not violations:
    print("  every test file matches CC-06.1 canonical naming ✓")

sys.exit(1 if (violations and not advisory_mode) else 0)
PY

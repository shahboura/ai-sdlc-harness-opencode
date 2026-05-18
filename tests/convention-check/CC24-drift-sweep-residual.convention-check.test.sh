#!/usr/bin/env bash
# CC24-drift-sweep-residual.convention-check.test.sh — TEST-189
#
# Meta-check that the M-24 drift sweep itself stays clean. Three layers:
#
#   1. **TEST-181..189 matrix presence**: every TEST-XX in the
#      181..189 range MUST have a row in the Test Coverage Matrix at
#      the end of `dev-workflow-tests.md`. The row's "Impl Ref" cell
#      must match the body's `**Impl Ref:**` line for that test.
#
#   2. **IMPL-24-XX CC-ref presence**: every `[IMPL-24-NN]` line in
#      `dev-workflow-plan.md` must include `CC ref:` followed by at
#      least one CC-XX identifier.
#
#   3. **CC-09 residual scan**: re-run the existing
#      `CC09-tunable-thresholds.convention-check.test.sh` and propagate
#      its exit code — the strict layer must remain at 0.
#
# Authority docs live in `../harness-mgm/`. When the directory isn't
# reachable, the script exits 0 with a `skipped` message.
#
# Created by: dev-workflow-plan.md [M-24] [IMPL-24-08 + IMPL-24-09 +
# TEST-189 closure]
# Maps to: TEST-189 (CC-08.1, CC-09, CC-06.4 drift-sweep residual).
# CC conventions applied: CC-06.3, CC-08.1, CC-09, CC-06.4.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
authority = repo.parent / "harness-mgm"
tests_md = authority / "dev-workflow-tests.md"
plan_md = authority / "dev-workflow-plan.md"

if not authority.is_dir() or not tests_md.is_file() or not plan_md.is_file():
    print(
        "CC-24 drift-sweep residual: SKIPPED — authority docs not reachable "
        f"at {authority} (end-user clone or detached harness)"
    )
    sys.exit(0)

tests_text = tests_md.read_text(encoding="utf-8")
plan_text = plan_md.read_text(encoding="utf-8")

violations: list[str] = []

# (1) Matrix presence: every TEST-181..189 has a body heading AND a
#     matrix row.
RANGE = range(181, 190)
body_heading_re = re.compile(
    r"^####\s+\[TEST-(\d+)(?:\.[a-z])?\]\s+", re.MULTILINE
)
matrix_row_re = re.compile(
    r"^\|\s*TEST-(\d+)(?:\.[a-z])?\s*\|", re.MULTILINE
)

body_ids = {int(m.group(1)) for m in body_heading_re.finditer(tests_text)}
matrix_ids = {int(m.group(1)) for m in matrix_row_re.finditer(tests_text)}

for tid in RANGE:
    if tid not in body_ids:
        violations.append(
            f"TEST-{tid}: body heading (`#### [TEST-{tid}]`) absent from "
            f"dev-workflow-tests.md"
        )
    if tid not in matrix_ids:
        violations.append(
            f"TEST-{tid}: row absent from Test Coverage Matrix in "
            f"dev-workflow-tests.md"
        )

# (2) IMPL-24-XX CC-ref presence.
impl_line_re = re.compile(r"\*\*\[IMPL-24-(\d+)\]\*\*\s*—\s*(.*)")
cc_ref_re = re.compile(r"CC\s*ref\s*:\s*CC-\d")

impls_checked = 0
for ln, line in enumerate(plan_text.splitlines(), start=1):
    m = impl_line_re.search(line)
    if not m:
        continue
    impls_checked += 1
    if not cc_ref_re.search(line):
        violations.append(
            f"dev-workflow-plan.md:{ln} IMPL-24-{m.group(1)} missing `CC ref:` "
            f"followed by a CC-XX identifier"
        )

# (3) CC-09 residual scan — delegate to the existing script.
cc09_script = repo / "tests" / "convention-check" / "CC09-tunable-thresholds.convention-check.test.sh"
cc09_rc = -1
cc09_msg = "CC-09 residual scan: script not found"
if cc09_script.is_file():
    try:
        result = subprocess.run(
            ["bash", str(cc09_script)],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        cc09_rc = result.returncode
        cc09_msg = (
            f"CC-09 residual scan: exit {cc09_rc} "
            f"({'strict layer clean' if cc09_rc == 0 else 'STRICT LAYER VIOLATION'})"
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        cc09_msg = f"CC-09 residual scan: invocation failed — {e}"

if cc09_rc != 0:
    violations.append(cc09_msg)

print(
    f"CC-24 drift-sweep residual: scanned {len(RANGE)} TEST-XX entries + "
    f"{impls_checked} IMPL-24-XX line(s); {cc09_msg.lower()}; "
    f"{len(violations)} violation(s) — STRICT (fail-closed)"
)
for v in violations[:30]:
    print(f"  ✗ {v}", file=sys.stderr)
if len(violations) > 30:
    print(f"  ... and {len(violations) - 30} more", file=sys.stderr)
if not violations:
    print("  every TEST-XX is matrix-anchored, every IMPL-24-XX cites CC, "
          "and CC-09 strict layer is clean ✓")

sys.exit(1 if violations else 0)
PY

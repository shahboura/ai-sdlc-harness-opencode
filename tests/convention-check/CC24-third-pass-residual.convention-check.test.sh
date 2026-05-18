#!/usr/bin/env bash
# CC24-third-pass-residual.convention-check.test.sh — TEST-190
#
# Per the M-24 third-pass patch: this Convention-Check directly gates
# the four convention-document amendments that the second-pass audit
# identified as lacking dedicated Red tests:
#
#   IMPL-24-03: CC-08.4 "Standing acceptable-variance invocations"
#               subheading + ≥1 row mentioning Mermaid `classDef`.
#   IMPL-24-04: CC-09 footer declares the four sub-rule literals
#               (Consumer-code / Design-prose / Mermaid-fence
#               exclusion CC-09.1 / File-level waiver CC-09.2).
#   IMPL-24-05: CC-06.4 bullet `Every **command file**`.
#   IMPL-24-06: dev-workflow-phase-specs.md P6 Artifacts Produced
#               table declares `pre-pr-report.md` at the canonical
#               disk path (not `(console)`).
#
# Authority docs live in `../harness-mgm/`. When the directory isn't
# reachable, the script exits 0 with a `skipped` message.
#
# Created by: dev-workflow-plan.md [M-24 third-pass patch]
#             [IMPL-24-03 + -04 + -05 + -06 + TEST-190 closure]
# Maps to: TEST-190 (CC-07.3, CC-06.4 third-pass patch residual).
# CC conventions applied: CC-07.3, CC-06.4, CC-08.4, CC-09, CC-06.2.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
authority = repo.parent / "harness-mgm"
cc_md = authority / "cc-conventions.md"
specs_md = authority / "dev-workflow-phase-specs.md"

if not authority.is_dir() or not cc_md.is_file() or not specs_md.is_file():
    print(
        "CC-24 third-pass residual: SKIPPED — authority docs not reachable "
        f"at {authority} (end-user clone or detached harness)"
    )
    sys.exit(0)

cc_text = cc_md.read_text(encoding="utf-8")
specs_text = specs_md.read_text(encoding="utf-8")

violations: list[str] = []

# IMPL-24-03: CC-08.4 standing acceptable-variance invocations.
if "Standing acceptable-variance invocations" not in cc_text:
    violations.append(
        "IMPL-24-03: cc-conventions.md missing literal "
        "`Standing acceptable-variance invocations`"
    )
elif not re.search(r"classDef", cc_text):
    # Loose check — the table row must mention `classDef`.
    violations.append(
        "IMPL-24-03: cc-conventions.md has the Standing-Variance "
        "subheading but no row mentions `classDef`"
    )

# IMPL-24-04: CC-09 footer's four sub-rule literals.
required_cc09 = [
    "Consumer-code layer (fail-closed)",
    "Design-prose layer (advisory)",
    "Mermaid-fence exclusion (CC-09.1",
    "File-level waiver (CC-09.2",
]
for lit in required_cc09:
    if lit not in cc_text:
        violations.append(
            f"IMPL-24-04: cc-conventions.md CC-09 footer missing literal `{lit}`"
        )

# IMPL-24-05: CC-06.4 bullet on command files.
if "Every **command file**" not in cc_text:
    violations.append(
        "IMPL-24-05: cc-conventions.md CC-06.4 missing the "
        "`Every **command file**` coverage bullet"
    )

# IMPL-24-06: P6 Artifacts Produced declares `pre-pr-report.md` on disk.
# The canonical path uses placeholder tokens — match the suffix.
pre_pr_pattern = re.compile(
    r"ai/<YYYY-MM-DD>-<work-item-id>/pre-pr-report\.md"
)
if not pre_pr_pattern.search(specs_text):
    violations.append(
        "IMPL-24-06: dev-workflow-phase-specs.md P6 Artifacts Produced "
        "missing canonical path "
        "`ai/<YYYY-MM-DD>-<work-item-id>/pre-pr-report.md`"
    )
else:
    # Belt-and-braces: the `(console)` regression must be gone for the
    # Pre-PR Report row specifically.
    p6_match = re.search(r"^###\s+P6\s+—\s+", specs_text, re.MULTILINE)
    if p6_match:
        end_match = re.search(r"^###\s", specs_text[p6_match.end():], re.MULTILINE)
        end = p6_match.end() + (
            end_match.start() if end_match else len(specs_text) - p6_match.end()
        )
        section = specs_text[p6_match.start():end]
        # Find the Pre-PR Report row.
        for line in section.splitlines():
            if "**Pre-PR Report**" in line and "(console)" in line and "pre-pr-report.md" not in line:
                violations.append(
                    "IMPL-24-06: Pre-PR Report row regressed to "
                    "`(console)` — should declare disk path"
                )
                break

print(
    f"CC-24 third-pass residual: checked 4 IMPL-24-XX literals across "
    f"cc-conventions.md + dev-workflow-phase-specs.md; "
    f"{len(violations)} violation(s) — STRICT (fail-closed)"
)
for v in violations[:20]:
    print(f"  ✗ {v}", file=sys.stderr)
if not violations:
    print("  every third-pass-patch literal anchored in the canonical docs ✓")

sys.exit(1 if violations else 0)
PY

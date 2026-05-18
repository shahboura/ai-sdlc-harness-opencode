#!/usr/bin/env bash
# CC07-04-phase-heading-style.convention-check.test.sh — TEST-188
#
# Per CC-07.1 + VAG-15, every phase-section heading in both
# `dev-workflow-phases.md` and `dev-workflow-phase-specs.md` uses the
# canonical em-dash style:
#
#     ### P0 — Workspace Bootstrap
#     ### P5.5 — Static Security Review
#     ### IG — Inter-Gate Ad-Hoc Request Handling
#     ### R — Workflow State Recovery
#
# Bare-style headings (`### P0 Workspace Bootstrap`) are flagged. The
# check matches heading lines whose third-level heading begins with a
# phase identifier (P0..Pn, P5.5, IG, R) and asserts the ` — ` separator
# is present between the ID and the phase name.
#
# Authority docs live in `../harness-mgm/`. When the directory isn't
# reachable, the script exits 0 with a `skipped` message.
#
# Created by: dev-workflow-plan.md [M-24] [IMPL-24-07 + TEST-188 closure]
# Maps to: TEST-188 (CC-07.1 / VAG-15 heading-style normalisation).
# CC conventions applied: CC-07.1, CC-06.2, CC-08.4.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
authority = repo.parent / "harness-mgm"
targets = [authority / "dev-workflow-phases.md", authority / "dev-workflow-phase-specs.md"]

if not authority.is_dir() or not all(t.is_file() for t in targets):
    print(
        "CC-07.1 phase-heading style: SKIPPED — authority docs not reachable "
        f"at {authority} (end-user clone or detached harness)"
    )
    sys.exit(0)

# Match `### <phase-id> <separator?> <name>` — phase IDs:
#   P0..P9, P0.x..P9.x (P2.5, P5.5, ...), IG, R.
phase_id = r"(?:P\d+(?:\.\d+)?|IG|R)"
heading_re = re.compile(rf"^###\s+({phase_id})\s+(.+?)\s*$")

violations: list[str] = []
checked = 0

for target in targets:
    rel = target.relative_to(authority)
    text = target.read_text(encoding="utf-8")
    for ln, line in enumerate(text.splitlines(), start=1):
        m = heading_re.match(line)
        if not m:
            continue
        _phase, rest = m.group(1), m.group(2)
        checked += 1
        # The first token of `rest` must be `—` (em-dash, U+2014).
        if not rest.startswith("— "):
            violations.append(
                f"[CC-07.4.4-style] phase heading at {rel}:{ln} uses bare style "
                f"— normalise to em-dash"
            )

print(
    f"CC-07.1 phase-heading style: scanned {checked} phase heading(s) across "
    f"{len(targets)} authority doc(s); {len(violations)} bare-style violation(s) "
    f"— STRICT (fail-closed)"
)
for v in violations[:30]:
    print(f"  ✗ {v}", file=sys.stderr)
if len(violations) > 30:
    print(f"  ... and {len(violations) - 30} more", file=sys.stderr)
if not violations:
    print("  every phase heading uses canonical em-dash style ✓")

sys.exit(1 if violations else 0)
PY

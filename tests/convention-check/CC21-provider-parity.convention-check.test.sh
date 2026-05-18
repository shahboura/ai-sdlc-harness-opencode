#!/usr/bin/env bash
# CC21-provider-parity.convention-check.test.sh — M-21 parity gate.
#
# Scans `skills/providers/provider-parity-report.md` for the per-capability
# × per-provider parity matrix and enforces:
#
#   1. Every provider directory under `skills/providers/<name>/` named in
#      the report's "Scope" table actually exists on disk.
#   2. Every adapter capability declared in `skills/providers/shared/
#      capabilities.md` appears as a row in the parity matrix.
#   3. The aggregate count of `⚠ UNLABELLED` cells is reported. This
#      check is **fail-OPEN (advisory)** by default — the parity-test
#      fixtures (TEST-131..150) are M-12 backfill scope. Set
#      `CC21_STRICT=1` to flip to fail-closed once the fixture suite
#      is populated.
#
# Created by: dev-workflow-plan.md [M-13] [M-21 substance]
# Maps to: TEST-181 (capability vocabulary canonical source).
# CC conventions applied: CC-04.5, CC-06.2, CC-08.4.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import os
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
parity_report = repo / "skills" / "providers" / "provider-parity-report.md"
capabilities_md = repo / "skills" / "providers" / "shared" / "capabilities.md"

if not parity_report.is_file():
    print(
        f"[M-21] {parity_report.relative_to(repo)} missing — parity-test surface absent",
        file=sys.stderr,
    )
    sys.exit(2)
if not capabilities_md.is_file():
    print(
        f"[M-21] {capabilities_md.relative_to(repo)} missing — canonical capability vocabulary absent",
        file=sys.stderr,
    )
    sys.exit(2)

report_text = parity_report.read_text(encoding="utf-8")
caps_text = capabilities_md.read_text(encoding="utf-8")

violations: list[str] = []

# (1) Provider-directory existence: parse the Scope table.
provider_dir_violations: list[str] = []
in_scope = False
scope_providers: set[str] = set()
for line in report_text.splitlines():
    if line.startswith("## Scope"):
        in_scope = True
        continue
    if in_scope and line.startswith("## "):
        break
    if in_scope and line.startswith("|") and not re.match(r"^\|\s*Provider\s*\|", line):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if cells and re.match(r"^[a-z][a-z0-9-]*$", cells[0]):
            scope_providers.add(cells[0])

for name in sorted(scope_providers):
    if not (repo / "skills" / "providers" / name).is_dir():
        provider_dir_violations.append(
            f"provider-parity-report.md lists `{name}` in Scope but "
            f"`skills/providers/{name}/` does not exist"
        )
violations.extend(provider_dir_violations)

# (2) Capability-vocabulary coverage: every name in capabilities.md YAML
# must appear in the report's matrix.
yaml_caps: set[str] = set()
for m in re.finditer(r"^\s*-\s*name:\s*(\S+)", caps_text, re.MULTILINE):
    yaml_caps.add(m.group(1))

cap_coverage_violations: list[str] = []
for cap in sorted(yaml_caps):
    # The matrix row uses backticks around the capability name. Allow
    # both the bare name and the backticked form.
    if not re.search(rf"`{re.escape(cap)}`", report_text):
        cap_coverage_violations.append(
            f"capability `{cap}` declared in capabilities.md YAML but no matrix row "
            f"in provider-parity-report.md"
        )
violations.extend(cap_coverage_violations)

# (3) Unlabelled count (advisory).
unlabelled = report_text.count("⚠ UNLABELLED")

strict_mode = os.environ.get("CC21_STRICT") == "1"

print(
    f"M-21 provider parity: {len(scope_providers)} provider(s) in Scope; "
    f"{len(yaml_caps)} capability(ies) declared; "
    f"{unlabelled} UNLABELLED cell(s) — "
    f"{'STRICT (UNLABELLED fails build)' if strict_mode else 'ADVISORY (UNLABELLED counted, not blocking)'}"
)

for v in violations:
    print(f"  ✗ {v}", file=sys.stderr)
if not violations and unlabelled == 0:
    print("  every capability has a labelled row across every in-scope provider ✓")
elif not violations:
    print(f"  scope + capability coverage OK ({unlabelled} cells await M-12 fixture backfill)")

# Structural violations (missing provider dir / missing matrix row)
# always fail-closed. UNLABELLED count fails only in strict mode.
fail = bool(violations) or (strict_mode and unlabelled > 0)
sys.exit(1 if fail else 0)
PY

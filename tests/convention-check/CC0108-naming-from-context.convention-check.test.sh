#!/usr/bin/env bash
# CC0108-naming-from-context.convention-check.test.sh — TEST-106
#
# Per CC-01.8, every consumer of the naming templates (branch / commit /
# PR-title / tag) reads them from `.claude/context/naming-config.md` at
# runtime — never hardcodes the literals. Each consumer command file
# MUST carry a header-block citation pointing at naming-config.md so a
# reviewer can confirm the contract by reading the file's top section.
#
# The four canonical consumers (per IMPL-15-04):
#   skills/dev-workflow/commands/preflight.md     — branch_format
#   skills/dev-workflow/commands/develop.md       — commit_format
#   skills/dev-workflow/commands/create-pr.md     — pr_title_format
#   skills/dev-workflow/commands/reconcile.md     — commit_format (archive)
#
# Each must contain a header line matching the canonical citation form:
#
#     > Naming-config (M-15 IMPL-15-04): … naming-config.md … CC-01.8
#
# within the first 30 lines.
#
# Created by: dev-workflow-plan.md [M-13] [IMPL-13-02-EXT-C]
# Maps to: TEST-106 (CC-01.8 naming-from-context).
# CC conventions applied: CC-01.8, CC-04.5, CC-06.2.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])

CONSUMERS = [
    "skills/dev-workflow/commands/preflight.md",
    "skills/dev-workflow/commands/develop.md",
    "skills/dev-workflow/commands/create-pr.md",
    "skills/dev-workflow/commands/reconcile.md",
]

# Citation must mention `naming-config.md` AND `CC-01.8` in the same
# blockquote line (`> …`) within the first 30 lines. The exact phrasing
# varies per consumer (each cites the format it consumes) but the
# anchor terms are uniform.
_CITATION_RE = re.compile(
    r"^>\s*.*naming-config\.md.*CC-01\.8|^>\s*.*CC-01\.8.*naming-config\.md",
    re.IGNORECASE | re.MULTILINE,
)
HEADER_LINES = 30

violations: list[str] = []
checked = 0
for rel in CONSUMERS:
    path = repo / rel
    if not path.is_file():
        violations.append(f"{rel}: missing — consumer file does not exist")
        continue
    checked += 1
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        violations.append(f"{rel}: unreadable ({e})")
        continue
    head = "\n".join(content.splitlines()[:HEADER_LINES])
    if not _CITATION_RE.search(head):
        violations.append(
            f"{rel}: header (first {HEADER_LINES} lines) missing "
            f"`> ... naming-config.md ... CC-01.8` citation (CC-01.8)"
        )

print(f"CC-01.8 naming-from-context: scanned {checked} consumer file(s)")
for v in violations:
    print(f"  ✗ {v}", file=sys.stderr)
if not violations:
    print("  every consumer cites naming-config.md ✓")

sys.exit(1 if violations else 0)
PY

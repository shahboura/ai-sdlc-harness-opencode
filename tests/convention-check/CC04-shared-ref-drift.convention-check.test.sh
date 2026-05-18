#!/usr/bin/env bash
# CC04-shared-ref-drift.convention-check.test.sh — TEST-70
#
# Per CC-04.4 / CC-04.6, every shared file MUST declare an owner and a
# version in a two-line header block:
#
#     > Owner: <phase | cross-cutting>
#     > Version: <semver>
#
# These headers are the anchor for CC-04.5 drift detection: when a
# consumer references a shared file's content inline (instead of via a
# citation), reviewers can compare the local copy's effective version
# against the shared file's declared version. Without the version
# header, drift cannot be diagnosed mechanically.
#
# This check scans the three canonical shared-content roots and asserts
# every `.md` file declares both header lines within its first 10 lines.
# Roots checked:
#   agents/shared/
#   skills/dev-workflow/context/
#   skills/providers/shared/
#
# Not checked: per-skill snippets (each skill is single-ownership), the
# providers/<name>/ adapter files (those declare per-capability tables,
# not shared content), and the README files (not workflow shared).
#
# A future extension (deferred) would also detect inline reproductions
# of shared content — that requires a content-signature index across
# the corpus and is left to a follow-up implementation.
#
# Created by: dev-workflow-plan.md [M-13] [IMPL-13-02]
# Maps to: TEST-70 (CC-04.5 shared-ref drift; header-presence subset).
# CC conventions applied: CC-04.4, CC-04.5, CC-04.6, CC-06.2.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])

SHARED_ROOTS = [
    "agents/shared",
    "skills/dev-workflow/context",
    "skills/providers/shared",
]

_OWNER_RE = re.compile(r"^>\s*Owner:\s*\S", re.MULTILINE)
_VERSION_RE = re.compile(r"^>\s*Version:\s*\d+(\.\d+)*", re.MULTILINE)
HEADER_LINES = 10

violations: list[str] = []
checked = 0

for root in SHARED_ROOTS:
    full = repo / root
    if not full.is_dir():
        continue
    for path in sorted(full.glob("*.md")):
        checked += 1
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            violations.append(f"{path.relative_to(repo)}: unreadable ({e})")
            continue
        head = "\n".join(content.splitlines()[:HEADER_LINES])
        missing: list[str] = []
        if not _OWNER_RE.search(head):
            missing.append("`> Owner: <phase|cross-cutting>`")
        if not _VERSION_RE.search(head):
            missing.append("`> Version: <semver>`")
        if missing:
            violations.append(
                f"{path.relative_to(repo)}: header (first {HEADER_LINES} lines) "
                f"missing {' + '.join(missing)} (CC-04.4 / CC-04.6)"
            )

print(f"CC-04.4/4.6 shared-file headers: scanned {checked} shared file(s)")
for v in violations:
    print(f"  ✗ {v}", file=sys.stderr)
if not violations:
    print("  every shared file declares Owner + Version ✓")

sys.exit(1 if violations else 0)
PY

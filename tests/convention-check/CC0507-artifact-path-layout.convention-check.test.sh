#!/usr/bin/env bash
# CC0507-artifact-path-layout.convention-check.test.sh — TEST-107
#
# Per CC-05.7 / GAP-21, every per-workflow artifact must live under
# `ai/<YYYY-MM-DD>-<safe-id>/`. The legacy layouts (`ai/plans/...`,
# `ai/tasks/...`) are forbidden in consumer code — any reference to them
# in a writeable position (Write/Edit/Bash redirect-target) indicates
# drift from the M-14 path migration.
#
# This check scans skill SKILL.md files + commands/ files for write-side
# references to the legacy paths. Read-side references (e.g. backward-
# compat fallback "OR `ai/plans/*`") are allowed because the M-14
# consumer sweep deliberately keeps a dual-layout reader during the
# migration window — only writes are forbidden.
#
# Fail policy: **fail-CLOSED (strict)** as of 2026-05-18. The M-14 consumer
# migration completed for `create-pr.md` and `review-response.md` (every
# write-side reference now uses the canonical
# `ai/<YYYY-MM-DD>-<work-item-id>/` form). Set `CC0507_ADVISORY=1` to flip
# back to fail-open if a follow-up consumer regresses and needs a
# migration window of its own.
#
# Created by: dev-workflow-plan.md [M-13] [IMPL-13-02]
# Maps to: TEST-107 (CC-05.7 artifact-path-layout).
# CC conventions applied: CC-05.7, CC-04.5, CC-06.2.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import os
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])

# Write-side reference patterns. Each is a regex with a one-line context.
# We're looking for instructions that would CAUSE a write to legacy paths,
# not for prose mentions of them as historical context.
WRITE_PATTERNS = [
    # Markdown instructions like "Save to: ai/plans/..."
    (re.compile(r"(?:Save to|save to|write to|Write to|written to|Output:)[^\n]*ai/plans/", re.IGNORECASE),
     "skill/command instructs writing to legacy ai/plans/"),
    (re.compile(r"(?:Save to|save to|write to|Write to|written to|Output:)[^\n]*ai/tasks/", re.IGNORECASE),
     "skill/command instructs writing to legacy ai/tasks/"),
    # Bash redirect-target patterns (best-effort — captures `> ai/plans/foo.md`)
    (re.compile(r"(?:>|>>)\s*['\"]?ai/plans/", re.MULTILINE),
     "bash redirect target points at legacy ai/plans/"),
    (re.compile(r"(?:>|>>)\s*['\"]?ai/tasks/", re.MULTILINE),
     "bash redirect target points at legacy ai/tasks/"),
    # cp/mv/git add into legacy paths
    (re.compile(r"\b(?:cp|mv|git add)\s+[^\n]*\bai/plans/", re.MULTILINE),
     "shell command writes into legacy ai/plans/"),
    (re.compile(r"\b(?:cp|mv|git add)\s+[^\n]*\bai/tasks/", re.MULTILINE),
     "shell command writes into legacy ai/tasks/"),
]

# Files to scan. Read-side consumer files (workflow-status, recovery-state,
# etc.) often reference legacy paths in fallback-read prose — that's OK.
# We focus on SKILL.md + commands/ which are the write-instruction sources.
SCAN_GLOBS = [
    "skills/**/SKILL.md",
    "skills/**/commands/*.md",
    "skills/init-workspace/*.md",
    "scripts/*.sh",
    "scripts/*.py",
]

# Files explicitly exempted (migration-script + tests that EXIST to handle
# the legacy paths). Each exemption is a relative path string.
EXEMPT = {
    # Migration script's sole purpose IS to move legacy layout to canonical.
    "scripts/migrate-ai-layout.sh",
}

# Per-line waiver mechanism: a line containing `CC-05.7-OK: <reason>` is
# exempted from this check. Use sparingly — e.g. read-side fallback prose
# that needs the literal legacy path as a grep anchor.
_LINE_WAIVER = re.compile(r"CC-05\.7-OK:")

violations: list[str] = []
scanned = 0
for glob in SCAN_GLOBS:
    for path in repo.glob(glob):
        rel = str(path.relative_to(repo)).replace(os.sep, "/")
        if rel in EXEMPT:
            continue
        scanned += 1
        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for pat, hint in WRITE_PATTERNS:
            for m in pat.finditer(content):
                line_no = content.count("\n", 0, m.start()) + 1
                line = content.splitlines()[line_no - 1] if line_no - 1 < len(content.splitlines()) else ""
                if _LINE_WAIVER.search(line):
                    continue
                violations.append(f"{rel}:{line_no}: {hint}; match: `{m.group(0).strip()}`")

advisory_mode = os.environ.get("CC0507_ADVISORY") == "1"
print(
    f"CC-05.7 artifact-path-layout: scanned {scanned} file(s); "
    f"{len(violations)} legacy-write violation(s) — "
    f"{'ADVISORY (fail-open via CC0507_ADVISORY=1)' if advisory_mode else 'STRICT (fail-closed; default post-M-14)'}"
)
for v in violations[:30]:
    print(f"  ✗ {v}", file=sys.stderr)
if len(violations) > 30:
    print(f"  ... and {len(violations) - 30} more", file=sys.stderr)
if not violations:
    print("  no write-side references to legacy ai/plans/ or ai/tasks/ ✓")

# Fail-closed by default (M-14 consumer migration complete); fail-open
# under CC0507_ADVISORY=1 if a follow-up consumer regresses and needs a
# transitional window.
sys.exit(1 if (violations and not advisory_mode) else 0)
PY

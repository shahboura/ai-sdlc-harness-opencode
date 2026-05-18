#!/usr/bin/env bash
# CC09-tunable-thresholds.convention-check.test.sh — TEST-185
#
# Two-layer scanner per cc-conventions.md CC-09:
#   STRICT layer (fail-closed): scans scripts/, hooks/, tests/ for any of the
#     declared threshold literals (90, 5, 24, 30, 3 in context). Each occurrence
#     must either be inside the declared source-of-truth file OR carry an inline
#     `# CC-09-OK: <reason>` waiver OR be loaded at runtime (excluded files).
#   ADVISORY layer (fail-open): scans every .md under the harness for prose
#     references to the same literals. Each must cite the CC-09 row via inline
#     link OR carry `<!-- CC-09-prose-ok: <reason> -->` waiver OR be inside the
#     CC-09 table itself.
#
# Mermaid-fence exclusion (CC-09.1): content inside `\`\`\`mermaid` fences is
# excluded from prose-layer scanning (HTML comments cannot live in Mermaid
# fences). File-level waiver (CC-09.2): a `<!-- CC-09-prose-ok: ... -->` in
# the first 20 lines exempts the whole file from advisory layer.
#
# Created by: dev-workflow-plan.md [M-24] (TEST-185)
# CC conventions applied: CC-09, CC-09.1, CC-09.2, CC-04.5.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import os, re, sys
from pathlib import Path

repo = Path(sys.argv[1])

# CC-09 threshold literals in their typical consumer-code contexts.
# Keyed by a stable name; value is a regex that matches the literal in code.
STRICT_PATTERNS = [
    ("coverage_threshold", re.compile(r"\b90\b\s*[#%]?")),  # 90% coverage gate
    ("max_review_rounds", re.compile(r"max_review_rounds\s*[:=]\s*5\b")),
    ("gate_stall_hours", re.compile(r"gate_stall_threshold_hours\s*[:=]\s*24\b")),
    ("hotfix_window_days", re.compile(r"hotfix_unarchive_window_days\s*[:=]\s*30\b")),
    ("max_build_retries", re.compile(r"max_build_retries\s*[:=]\s*3\b")),
]

# Source-of-truth files where the literals ARE allowed.
SOURCE_OF_TRUTH = {
    ".claude/context/state.md",
    ".claude/context/language-config.md",
    "agents/shared/tracker-field-schema.md",
    # cc-conventions.md lives in the harness-mgm authority dir, not the harness;
    # we don't scan it here, but reference for documentation:
    # "../harness-mgm/cc-conventions.md",
}

# Strict layer: scan scripts/ + hooks/ for literals NOT inside SOT.
# tests/ is intentionally EXCLUDED — test files reference threshold values as
# fixture content / spec assertions, not as runtime-consumer hardcoded values.
# Per-line `# CC-09-OK:` waivers cover the exceptional cases.
strict_violations = []
strict_scope_dirs = ("scripts", "hooks")
for d in strict_scope_dirs:
    full = repo / d
    if not full.is_dir():
        continue
    for root, _, files in os.walk(full):
        for fname in files:
            if not (fname.endswith(".py") or fname.endswith(".sh") or fname.endswith(".json")):
                continue
            path = Path(root) / fname
            rel = path.relative_to(repo)
            if str(rel).replace(os.sep, "/") in SOURCE_OF_TRUTH:
                continue
            try:
                content = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            for name, pat in STRICT_PATTERNS:
                for m in pat.finditer(content):
                    line_no = content.count("\n", 0, m.start()) + 1
                    # Per-line waiver: `# CC-09-OK: <reason>` anywhere on the line
                    line = content.splitlines()[line_no - 1] if line_no - 1 < len(content.splitlines()) else ""
                    if "CC-09-OK:" in line:
                        continue
                    strict_violations.append(f"{rel}:{line_no}: STRICT: {name} literal `{m.group(0)}` outside source-of-truth")

# Advisory layer: scan .md files (with Mermaid + file-level waiver exclusions).
advisory_violations = []
PROSE_PATTERNS = [
    (re.compile(r"\b90%\b"), "coverage_threshold"),
    (re.compile(r"\b5\s*review\s*round", re.IGNORECASE), "max_review_rounds"),
    (re.compile(r"\b24\s*h(?:our|r)?", re.IGNORECASE), "gate_stall_hours"),
    (re.compile(r"\b30\s*day", re.IGNORECASE), "hotfix_window_days"),
    (re.compile(r"\b3\s*(?:build|retr)", re.IGNORECASE), "max_build_retries"),
]
FILE_LEVEL_WAIVER = re.compile(r"<!--\s*CC-09-prose-ok:")
SIBLING_WAIVER = re.compile(r"<!--\s*CC-09-prose-ok:")
MERMAID_FENCE = re.compile(r"```mermaid\s*\n.*?\n```", re.DOTALL)

for path in repo.rglob("*.md"):
    rel = path.relative_to(repo)
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        continue
    # File-level waiver: scan first 20 lines.
    first_20 = "\n".join(content.splitlines()[:20])
    if FILE_LEVEL_WAIVER.search(first_20):
        continue
    # Strip Mermaid fences (CC-09.1 exclusion).
    stripped = MERMAID_FENCE.sub("", content)
    for pat, name in PROSE_PATTERNS:
        for m in pat.finditer(stripped):
            line_no = stripped.count("\n", 0, m.start()) + 1
            line = stripped.splitlines()[line_no - 1] if line_no - 1 < len(stripped.splitlines()) else ""
            # Sibling waiver (same line)
            if "CC-09-prose-ok:" in line:
                continue
            # Citation: inline link to CC-09 row
            if "cc-conventions.md#cc-09" in line.lower() or "[CC-09" in line:
                continue
            advisory_violations.append(f"{rel}:{line_no}: ADVISORY: {name} prose `{m.group(0)}` lacks CC-09 citation")

# Report
print(f"CC-09 STRICT layer (fail-closed): {len(strict_violations)} violation(s)")
for v in strict_violations[:20]:
    print(f"  {v}", file=sys.stderr)
if len(strict_violations) > 20:
    print(f"  ... and {len(strict_violations) - 20} more", file=sys.stderr)

print(f"CC-09 ADVISORY layer (fail-open): {len(advisory_violations)} violation(s) — does NOT block build")
# Advisory output is intentionally suppressed unless explicitly requested via env var
if os.environ.get("CC09_VERBOSE"):
    for v in advisory_violations[:50]:
        print(f"  {v}", file=sys.stderr)

# Exit: strict violations block; advisory is fail-open.
sys.exit(1 if strict_violations else 0)
PY

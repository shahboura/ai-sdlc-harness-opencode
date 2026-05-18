#!/usr/bin/env bash
# CC07-diagram-palette.convention-check.test.sh — TEST-184
#
# Scans every `.md` file in the harness for `\`\`\`mermaid` fences. For every
# fence, extracts the `classDef` block (lines starting with `classDef`) and
# verifies every line is byte-identical to a corresponding line in
# `agents/shared/diagram-styling.md` (canonical palette per M-01 IMPL-01-19 +
# CC-08.4 standing acceptable-variance invocation).
#
# Subset rule: a diagram may OMIT class lines (e.g. an overview without
# `:::orch` nodes drops `classDef orch`); it may NOT diverge any present line.
#
# Created by: dev-workflow-plan.md [M-24] [IMPL-24-XX] + TEST-184
# CC conventions applied: CC-08.4 (variance pinning), CC-04.5 (drift detection).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$REPO_ROOT/agents/shared/diagram-styling.md"

if [ ! -f "$CANONICAL" ]; then
    echo "FAIL: canonical palette file missing: $CANONICAL" >&2
    exit 2
fi

# Extract the canonical classDef lines (every line starting with "classDef").
canonical_lines=$(grep -E "^classDef " "$CANONICAL" | sort -u)
if [ -z "$canonical_lines" ]; then
    echo "FAIL: canonical palette file declares no classDef lines: $CANONICAL" >&2
    exit 2
fi

pass=0
fail=0
failures=()

# Scan every .md file (excluding the canonical itself and the harness-mgm authority docs).
while IFS= read -r -d '' md_file; do
    # Skip the canonical palette file (it owns the definitions).
    case "$md_file" in
        "$CANONICAL") continue ;;
    esac
    # Read the file, find each mermaid fence body, extract classDef lines.
    python3 - "$md_file" "$canonical_lines" <<'PY' || { failures+=("$md_file: validator crashed"); fail=$((fail+1)); continue; }
import re, sys

path = sys.argv[1]
canonical_text = sys.argv[2]
canonical_set = set(line.strip() for line in canonical_text.splitlines() if line.strip())

try:
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
except OSError as e:
    print(f"READ-ERROR: {path}: {e}", file=sys.stderr)
    sys.exit(2)

violations = []
for m in re.finditer(r"```mermaid\s*\n(.*?)\n```", text, re.DOTALL):
    body = m.group(1)
    line_offset = text.count("\n", 0, m.start()) + 2
    for i, ln in enumerate(body.splitlines()):
        if ln.strip().startswith("classDef "):
            if ln.strip() not in canonical_set:
                violations.append(f"{path}:{line_offset + i}: classDef line diverges from canonical: {ln.strip()!r}")

if violations:
    for v in violations:
        print(v, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
    rc=$?
    if [ $rc -eq 0 ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failures+=("$md_file: classDef divergence")
    fi
done < <(find "$REPO_ROOT" -type f -name "*.md" -not -path "*/node_modules/*" -not -path "*/.git/*" -print0)

echo "CC07-diagram-palette: $pass file(s) clean, $fail file(s) with divergent classDef lines"
if [ $fail -gt 0 ]; then
    echo "Failures:" >&2
    for f in "${failures[@]}"; do echo "  $f" >&2; done
    exit 1
fi
exit 0

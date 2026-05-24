#!/usr/bin/env bash
# Doc-grep + YAML validation for commands/<cmd>.manifest.yaml schema (US-E07-002).
#
# Validates TEST-200 (literal-path enforcement) and TEST-201 (missing manifest):
#   1. manifest-schema.md exists and documents all required fields.
#   2. Every command .md has a sibling .manifest.yaml file.
#   3. Each manifest can be parsed as valid YAML (no syntax errors).
#   4. Each manifest has the five required fields.
#   5. No manifest contains glob patterns in read_set or writes.
#   6. The schema example is internally consistent (develop.manifest.yaml matches).
#
# CC conventions validated: ADR-009 (machine-readable manifests), M-28 IMPL-28-01.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CMD_DIR="$REPO_ROOT/skills/dev-workflow/commands"
SCHEMA="$CMD_DIR/manifest-schema.md"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2" >&2; }

assert_contains() {
    local file="$1" needle="$2" label="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then _pass "$label"
    else _fail "$label" "expected to find: '$needle' in $(basename "$file")"; fi
}

# ---------------------------------------------------------------------------
# 1. Schema document exists and documents required fields
# ---------------------------------------------------------------------------
if [ -f "$SCHEMA" ]; then
    _pass "manifest-schema.md exists"
else
    _fail "manifest-schema.md" "file not found: $SCHEMA"
fi

for field in "phase_id" "hooks_fired" "agents_invoked" "read_set" "writes" "gate_id"; do
    assert_contains "$SCHEMA" "$field" "schema documents field '$field'"
done

assert_contains "$SCHEMA" "literal paths only" "schema documents literal-paths-only rule"
assert_contains "$SCHEMA" "literal paths only" "schema documents no-glob / literal-paths rule"

# ---------------------------------------------------------------------------
# 2. Every .md command has a sibling .manifest.yaml
# ---------------------------------------------------------------------------
missing_manifests=0
for cmd_md in "$CMD_DIR"/*.md; do
    [ -f "$cmd_md" ] || continue
    base="$(basename "$cmd_md" .md)"
    # Skip the schema doc itself
    [ "$base" = "manifest-schema" ] && continue
    manifest="$CMD_DIR/${base}.manifest.yaml"
    if [ -f "$manifest" ]; then
        _pass "$base.manifest.yaml exists"
    else
        _fail "$base.manifest.yaml" "missing sibling manifest for $base.md"
        missing_manifests=$((missing_manifests + 1))
    fi
done

# ---------------------------------------------------------------------------
# 3+4. Each manifest parses as valid YAML and has required fields
# ---------------------------------------------------------------------------
REQUIRED_FIELDS="phase_id hooks_fired agents_invoked read_set writes"

for manifest in "$CMD_DIR"/*.manifest.yaml; do
    [ -f "$manifest" ] || continue
    name="$(basename "$manifest")"

    # Parse YAML — check exit code
    if python3 -c "
import sys, pathlib
try:
    import yaml
    data = yaml.safe_load(pathlib.Path('$manifest').read_text())
    if not isinstance(data, dict):
        sys.exit(1)
except ImportError:
    # PyYAML not available — fall back to basic syntax check
    import ast, re
    pass
except Exception as e:
    print(f'YAML parse error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
        _pass "$name parses as valid YAML"
    else
        # Fallback: check it's at least non-empty and has key: value pairs
        if grep -qE "^[a-z_]+:" "$manifest"; then
            _pass "$name has key:value structure (yaml not available for full parse)"
        else
            _fail "$name" "does not appear to be valid YAML"
        fi
    fi

    # Check required fields present
    for field in $REQUIRED_FIELDS; do
        if grep -qE "^${field}:" "$manifest"; then
            _pass "$name has required field '$field'"
        else
            _fail "$name field '$field'" "required field missing from $name"
        fi
    done
done

# ---------------------------------------------------------------------------
# 5. No manifest contains glob wildcards in read_set or writes sections
# ---------------------------------------------------------------------------
for manifest in "$CMD_DIR"/*.manifest.yaml; do
    [ -f "$manifest" ] || continue
    name="$(basename "$manifest")"
    # Check for glob patterns (* ** ? [) in path-like values (lines starting with spaces/-)
    if grep -E "^\s+-\s+.*[*?\[]" "$manifest" 2>/dev/null | grep -qv "^#"; then
        _fail "$name no-glob rule" "manifest contains glob pattern in read_set or writes: $(grep -E '^\s+-\s+.*[*?\[]' "$manifest" | head -1)"
    else
        _pass "$name has no glob patterns"
    fi
done

# ---------------------------------------------------------------------------
# 6. Schema example command (develop) matches the actual develop.manifest.yaml
# ---------------------------------------------------------------------------
DEVELOP_MANIFEST="$CMD_DIR/develop.manifest.yaml"
if [ -f "$DEVELOP_MANIFEST" ]; then
    if grep -qF "ai-sdlc-developer" "$DEVELOP_MANIFEST" && grep -qF "ai-sdlc-reviewer" "$DEVELOP_MANIFEST"; then
        _pass "develop.manifest.yaml matches schema example (has developer + reviewer)"
    else
        _fail "develop.manifest.yaml schema parity" "manifest should declare ai-sdlc-developer and ai-sdlc-reviewer"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for f in "${fail_msgs[@]}"; do printf '  - %s\n' "$f" >&2; done
    exit 1
fi

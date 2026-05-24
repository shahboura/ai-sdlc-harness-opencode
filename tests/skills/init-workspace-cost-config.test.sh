#!/usr/bin/env bash
# Doc-grep regression: cost-config.md template + init-workspace wiring (US-E02-004).
#
# Validates:
#   1. Template file exists at the canonical path.
#   2. Template declares ADR-010 authority reference.
#   3. Template has a per-model rate table with the four cost columns.
#   4. Template has a currency field.
#   5. Template has provider pricing page links (at least Anthropic).
#   6. SKILL.md contains Step 6d referencing cost-config.md.
#   7. SKILL.md summary mentions cost-config.md.
#   8. Template null-safety comment: empty → "n/a" not "$0.00".
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/skills/init-workspace/templates/cost-config.md"
SKILL="$REPO_ROOT/skills/init-workspace/SKILL.md"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2" >&2; }

assert_contains() {
    local file="$1" needle="$2" label="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        _pass "$label"
    else
        _fail "$label" "expected to find: '$needle' in $(basename "$file")"
    fi
}

# 1. Template file exists
if [ -f "$TEMPLATE" ]; then
    _pass "cost-config.md template exists"
else
    _fail "template existence" "file not found: $TEMPLATE"
fi

# 2. ADR-010 authority reference
assert_contains "$TEMPLATE" "ADR-010" "template declares ADR-010 authority"

# 3. Rate table has four cost columns
assert_contains "$TEMPLATE" "input_per_1m" "template has input_per_1m column"
assert_contains "$TEMPLATE" "output_per_1m" "template has output_per_1m column"
assert_contains "$TEMPLATE" "cache_read_per_1m" "template has cache_read_per_1m column"
assert_contains "$TEMPLATE" "cache_write_per_1m" "template has cache_write_per_1m column"

# 4. Currency field
assert_contains "$TEMPLATE" "currency:" "template has currency field"

# 5. Anthropic pricing page link
assert_contains "$TEMPLATE" "anthropic.com/pricing" "template has Anthropic pricing link"

# 6. SKILL.md has Step 6d mentioning cost-config
assert_contains "$SKILL" "Step 6d" "SKILL.md has Step 6d"
assert_contains "$SKILL" "cost-config.md" "SKILL.md references cost-config.md"

# 7. SKILL.md summary mentions cost-config
if grep -A 20 "Step 7 — Summary" "$SKILL" | grep -qF "cost-config.md"; then
    _pass "SKILL.md summary mentions cost-config.md"
else
    _fail "SKILL.md summary" "Step 7 summary does not mention cost-config.md"
fi

# 8. Null-safety: empty → n/a comment present
assert_contains "$TEMPLATE" "n/a" "template null-safety: empty rates render as n/a"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for f in "${fail_msgs[@]}"; do printf '  - %s\n' "$f" >&2; done
    exit 1
fi

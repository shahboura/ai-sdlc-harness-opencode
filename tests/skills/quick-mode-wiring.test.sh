#!/usr/bin/env bash
# Doc-grep regression for US-E01-005 — quick-mode wiring.
#
# Verifies the three tagging requirements across the harness:
#   1. commands/quick.md: tracker has Mode: quick + quick-mode: true per FR-1.2
#   2. commands/quick.md: Quick-Mode: true footer required per FR-1.5
#   3. scripts/metrics_collector.py: extracts mode and writes mode column per FR-2.1
#   4. scripts/_validate_commit_msg.py: Quick-Mode: true is a documented trailer
#   5. agents/shared/tracker-field-schema.md: Mode: field v1.1 is present
#
# CC conventions validated: FR-1.2, FR-1.5, FR-1.7, FR-2.1, ADR-002.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

QUICK_CMD="$REPO_ROOT/skills/dev-workflow/commands/quick.md"
METRICS="$REPO_ROOT/scripts/metrics_collector.py"
VALIDATOR="$REPO_ROOT/scripts/_validate_commit_msg.py"
SCHEMA="$REPO_ROOT/agents/shared/tracker-field-schema.md"

# 1. Tracker tagging (FR-1.2)
assert_contains "$QUICK_CMD" "Mode: quick" "quick.md tracker has Mode: quick (FR-1.2)"
assert_contains "$QUICK_CMD" "quick-mode: true" "quick.md tracker has quick-mode: true (FR-1.2)"
assert_contains "$QUICK_CMD" "test-required: false" "quick.md tracker has test-required: false"

# 2. Commit footer (FR-1.5)
assert_contains "$QUICK_CMD" "Quick-Mode: true" "quick.md requires Quick-Mode: true footer (FR-1.5)"

# 3. Metrics mode column wiring (FR-1.7 / FR-2.1)
assert_contains "$METRICS" "_extract_mode" "metrics_collector extracts mode from tracker"
assert_contains "$METRICS" "Mode: quick" "metrics_collector recognises Mode: quick"
assert_contains "$METRICS" '"mode"' "metrics_collector has mode column in CSV_COLUMNS"

# 4. Commit validator documents Quick-Mode: true
assert_contains "$VALIDATOR" "Quick-Mode: true" "validate-commit-msg.py documents Quick-Mode: true"

# 5. tracker-field-schema.md has Mode: field (v1.1)
assert_contains "$SCHEMA" "Mode:" "tracker-field-schema has Mode: field"
assert_contains "$SCHEMA" "quick" "tracker-field-schema defines quick value for Mode:"
assert_contains "$SCHEMA" "1.1" "tracker-field-schema is at version 1.1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for f in "${fail_msgs[@]}"; do printf '  - %s\n' "$f" >&2; done
    exit 1
fi

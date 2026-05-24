#!/usr/bin/env bash
# Doc-grep regression for commands/report.md (US-E02-005 / US-E02-006).
#
# Validates:
#   1. report.md exists with --since, --format, --story arguments documented.
#   2. Null-safe token rule (CC-02.4.2): "n/a" not "$0.00" when empty.
#   3. "tokens unavailable" rendering when token fields are null.
#   4. cost-config.md is the rate source (ADR-010).
#   5. JSON format is declared with all required fields.
#   6. Per-story drill-down (--story) is declared (US-E02-006 scope).
#   7. report.manifest.yaml exists with correct phase and reads _metrics-log.csv.
#   8. SKILL.md commands table lists `report`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_CMD="$REPO_ROOT/skills/dev-workflow/commands/report.md"
REPORT_MANIFEST="$REPO_ROOT/skills/dev-workflow/commands/report.manifest.yaml"
SKILL="$REPO_ROOT/skills/dev-workflow/SKILL.md"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2" >&2; }

assert_contains() {
    local file="$1" needle="$2" label="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then _pass "$label"
    else _fail "$label" "expected: '$needle' in $(basename "$file")"; fi
}

# 1. File existence and argument documentation
[ -f "$REPORT_CMD" ] && _pass "report.md exists" || _fail "report.md" "file not found"
assert_contains "$REPORT_CMD" "--since" "report.md documents --since argument"
assert_contains "$REPORT_CMD" "--format" "report.md documents --format argument"
assert_contains "$REPORT_CMD" "--story" "report.md documents --story argument"
assert_contains "$REPORT_CMD" "30 days" "report.md defaults to 30-day window"

# 2. Null-safe cost (CC-02.4.2): n/a not $0.00
assert_contains "$REPORT_CMD" "n/a" "report.md renders n/a for absent cost"
assert_contains "$REPORT_CMD" "CC-02.4.2" "report.md cites CC-02.4.2 null-safe rule"

# 3. "tokens unavailable" for null token fields
assert_contains "$REPORT_CMD" "unavailable" "report.md renders tokens unavailable"
assert_contains "$REPORT_CMD" "null" "report.md explicitly handles null token fields"

# 4. cost-config.md as rate source (ADR-010)
assert_contains "$REPORT_CMD" "cost-config.md" "report.md reads cost-config.md (ADR-010)"
assert_contains "$REPORT_CMD" "input_per_1m" "report.md uses per-million rate columns"

# 5. JSON format declared
assert_contains "$REPORT_CMD" "json" "report.md supports JSON format"
assert_contains "$REPORT_CMD" '"work_item_id"' "report.md JSON has work_item_id field"
assert_contains "$REPORT_CMD" '"total_stories"' "report.md JSON has total_stories field"

# 6. Per-story drill-down (US-E02-006)
assert_contains "$REPORT_CMD" "Per-story drill-down" "report.md declares --story drill-down"
assert_contains "$REPORT_CMD" "US-E02-006" "report.md notes --story scope is US-E02-006"

# 7. Manifest
[ -f "$REPORT_MANIFEST" ] && _pass "report.manifest.yaml exists" || _fail "report.manifest.yaml" "file not found"
assert_contains "$REPORT_MANIFEST" "utility-report" "manifest declares phase_id: utility-report"
assert_contains "$REPORT_MANIFEST" "_metrics-log.csv" "manifest reads _metrics-log.csv"
assert_contains "$REPORT_MANIFEST" "cost-config.md" "manifest reads cost-config.md"

# 8. SKILL.md table
assert_contains "$SKILL" "| \`report\`" "SKILL.md lists report command"
assert_contains "$SKILL" "commands/report.md" "SKILL.md points to commands/report.md"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for f in "${fail_msgs[@]}"; do printf '  - %s\n' "$f" >&2; done
    exit 1
fi

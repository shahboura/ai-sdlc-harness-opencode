#!/usr/bin/env bash
# WS-7 regression coverage: skills/plan-generator/SKILL.md must declare a
# bounded pattern-hint step (5b) and must use `date -u` for filename dates.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="$REPO_ROOT/skills/plan-generator/SKILL.md"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

assert_contains() {
    if grep -qF -- "$1" "$FILE"; then _pass "$2"; else _fail "$2" "expected to find: $1"; fi
}
assert_regex() {
    if grep -qE -- "$1" "$FILE"; then _pass "$2"; else _fail "$2" "expected to match regex: $1"; fi
}
assert_not_regex() {
    if grep -qE -- "$1" "$FILE"; then _fail "$2" "must not match: $1"; else _pass "$2"; fi
}

# Task 1: Step 5b "Test Pattern References" exists with the bounded heuristic.
assert_contains '### 5b. Test Pattern References' 'plan-generator declares Step 5b'
assert_contains 'filename-globbing only' 'Step 5b restricts heuristic to filename globbing'
assert_contains 'does NOT read the contents of any candidate file' 'Step 5b forbids content reads (the FE-008 stall mode)'
assert_contains 'At most 5 globs' 'Step 5b caps glob count'
assert_contains 'at most 2 matches' 'Step 5b caps match count per task'

# Task 3: date commands all use -u.
assert_regex 'date -u \+%Y-%m-%d' 'plan-generator uses date -u for date-only fields'
assert_not_regex '(^|[^u] )date \+%Y' 'no `date +%Y` without -u'

# Task 1: Step 8 (GATE #1) mentions Test Pattern References.
assert_contains 'Test Pattern References' 'GATE #1 prompt mentions Test Pattern References'

# Plan document numbered list includes Test Pattern References at position 7
# and Task breakdown at 8 (renumbered correctly).
assert_regex '^7\. \*\*Test Pattern References\*\*' 'Plan document section list has Test Pattern References at #7'
assert_regex '^8\. Task breakdown table' 'Plan document section list has Task breakdown at #8'
assert_regex '^14\. Attribution footer' 'Plan document section list has Attribution at #14 (renumbered for the new section)'

# WS-4 task 2 — Minimum-input gate at Step 0a.
assert_contains '### 0a. Minimum-Input Gate' 'plan-generator declares Step 0a (Minimum-Input Gate)'
assert_contains 'At least one acceptance criterion' 'Step 0a checks for ≥ 1 acceptance criterion'
assert_contains 'At least one repo configured' 'Step 0a checks for ≥ 1 configured repo'
assert_contains 'bounce back' 'Step 0a documents bouncing back to story-intake on failure'

# WS-4 task 2 — Phase 7 Amendment Mode (MODE: pr-response-tasks).
assert_contains '## Phase 7 Amendment Mode (`MODE: pr-response-tasks`)' 'plan-generator declares Phase 7 Amendment Mode'
assert_contains '## Amendments (PR Review Round <N>)' 'amendment-row template uses the canonical heading'
assert_contains 'PR-comment: [PC-<n>] thread_id=' 'amendment Notes column carries PR-comment thread_id'
assert_contains 'do NOT reorder, edit, or remove any existing' 'amendment mode forbids mutating existing rows'
assert_contains 'tracker-transition-guard' 'amendment mode references the transition guard (rows must start Pending)'

# WS-4 task 2 — review-response.md handoff is wired to the skill section.
REVIEW_RESPONSE="$REPO_ROOT/skills/dev-workflow/commands/review-response.md"
if grep -qF '**Phase 7 Amendment Mode**' "$REVIEW_RESPONSE"; then
    _pass 'review-response.md Step 7 references plan-generator Phase 7 Amendment Mode'
else
    _fail 'review-response.md Step 7 references plan-generator Phase 7 Amendment Mode' \
        'expected the orchestrator prompt to pointer-reference the skill section'
fi
if grep -qE '^- Round:' "$REVIEW_RESPONSE"; then
    _pass 'review-response.md passes Round: N into the planner prompt'
else
    _fail 'review-response.md passes Round: N into the planner prompt' \
        'expected a `Round: <N>` line in the CONTEXT block of the planner invocation'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

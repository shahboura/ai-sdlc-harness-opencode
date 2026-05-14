#!/usr/bin/env bash
# WS-5 task 2 follow-up — Developer's API-compatibility check is now a
# precondition (new Step 4) instead of a Build-Failure-Recovery bullet.
# Catches a regression that re-buries the check in the recovery path or
# breaks the step renumbering.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="$REPO_ROOT/agents/developer/index.md"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

assert_contains() {
    if grep -qF -- "$1" "$FILE"; then _pass "$2"; else _fail "$2" "expected to find: $1"; fi
}
assert_regex() {
    if grep -qE -- "$1" "$FILE"; then _pass "$2"; else _fail "$2" "expected regex: $1"; fi
}

# Step 4 is the new API-compat precondition.
assert_regex '^4\. \*\*API-compatibility precondition' \
    'developer Step 4 is now the API-compat precondition'
assert_contains 'BEFORE writing any production code' \
    'precondition explicitly says BEFORE writing code'
assert_contains '[API: <lib> v<version>]' \
    'precondition reads the plan-generator annotation token'
assert_contains 'NOT the latest stable, NOT memory' \
    'precondition forbids trusting memory or latest-stable docs'

# Step 5 is now "Implement" — the old Step 4 — and the step list
# extends to Step 8 (Report worktree details).
assert_regex '^5\. \*\*Implement\*\* the task' \
    'developer Step 5 is "Implement" (post-precondition)'
assert_regex '^6\. \*\*Self-review before committing\*\*' \
    'developer Step 6 is Self-review (renumbered)'
assert_regex '^7\. \*\*Commit production code only\*\*' \
    'developer Step 7 is Commit (renumbered)'
assert_regex '^8\. \*\*Report worktree details\*\*' \
    'developer Step 8 is Report (renumbered)'

# Build Failure Recovery now treats API mismatch as a "Step 4 escape",
# not a primary recovery path.
assert_contains 'Step 4 already verifies every `[API: <lib> v<version>]`' \
    'Build Failure Recovery references Step 4 precondition (proactive, not reactive)'
assert_contains 'Step 4 escape' \
    'Build Failure Recovery frames API mismatch as a precondition escape'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

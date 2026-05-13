#!/usr/bin/env bash
# WS-7 regression coverage: skills/dev-workflow/commands/develop.md must use
# WORKTREE_CTX for first-launch agents and must NOT instruct the tester or
# developer to create their own worktree (orchestrator owns worktree
# creation per Step 1 sub-step 5).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="$REPO_ROOT/skills/dev-workflow/commands/develop.md"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

assert_contains() {
    local needle="$1"
    local label="$2"
    if grep -qF -- "$needle" "$FILE"; then
        _pass "$label"
    else
        _fail "$label" "expected to find: $needle"
    fi
}

assert_not_contains() {
    local needle="$1"
    local label="$2"
    if grep -qF -- "$needle" "$FILE"; then
        _fail "$label" "must not appear in develop.md: $needle"
    else
        _pass "$label"
    fi
}

# Present: orchestrator owns worktree creation in Step 1 sub-step 5.
assert_contains 'Create the worktree' 'develop.md declares Step 1 sub-step 5'
assert_contains 'WORKTREE_FAILED=false' 'develop.md has the worktree-failed flag flow'
assert_contains 'git -C "<REPO_PATH>" worktree add' 'develop.md inlines the worktree-add command'

# Present: first-launch agents use WORKTREE_CTX, not REPO_CTX.
assert_contains 'Include WORKTREE_CTX if WORKTREE_FAILED=false, else REPO_CTX with `worktree_failed: true`' \
    'tester/developer prompts conditionally select WORKTREE_CTX vs REPO_CTX'

# Absent: any text instructing the agent to create its own worktree. These
# exact strings were removed in WS-7; a regression that re-adds them must
# fail this test.
assert_not_contains 'Create a worktree with a fresh branch' 'tester prompt no longer instructs worktree creation'
assert_not_contains 'Create a worktree in this repo and work inside it' 'developer prompt no longer instructs worktree creation'
assert_not_contains 'If worktree creation fails, report it in AGENT STATUS' 'agent-side worktree-failure reporting removed'

# Tester prompt explicitly tells the agent not to create another worktree.
assert_contains 'DO NOT create another one' 'agent prompts forbid creating a worktree'

# PATTERN_HINTS_CTX wired into the tester launch (Task 1).
assert_contains 'PATTERN_HINTS_CTX from the plan' 'tester prompt includes PATTERN_HINTS_CTX'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

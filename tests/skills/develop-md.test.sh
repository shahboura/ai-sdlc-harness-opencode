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

# WS-5 dev-loop hardening — UID8 generation must hard-fail when empty
# (prevents a worktree branch like `worktree/<story>-t<n>-` colliding).
assert_contains 'if [ -z "$UID8" ]; then' 'develop.md hard-fails when UID8 is empty'
assert_contains 'UID8 generation failed' 'develop.md surfaces the UID8-failure cause to the human'

# B1 — WORKTREE_PATH must carry the UID8 suffix so a crashed-mid-task
# session can resume without colliding with the orphan worktree on disk.
assert_contains 'WORKTREE_PATH="<REPO_PATH>/../worktrees/<repo-name>-t<n>-${UID8}"' \
    'WORKTREE_PATH includes UID8 (post-crash resume safety)'
# Negative — the pre-B1 path shape without UID8 must not reappear.
assert_not_contains 'WORKTREE_PATH="<REPO_PATH>/../worktrees/<repo-name>-t<n>"' \
    'pre-B1 path shape (no UID8) is gone'

# A3 — worktree-failed fallback handling for squash-merge.
# In worktree mode the orchestrator uses `git merge --squash <worktree-branch>`;
# in fallback mode there is no worktree branch and it must use
# `git reset --soft <feature_head>` followed by a fresh commit instead.
# Both paths must be documented; if either disappears the fallback regresses.
assert_contains 'Worktree mode (`worktree_failed: false`):' 'Step 4 documents the worktree-mode squash path'
assert_contains 'Fallback mode (`worktree_failed: true`):' 'Step 4 documents the fallback-mode squash path'
assert_contains 'git -C "$REPO_PATH" reset --soft' 'Step 4 fallback uses git reset --soft'
assert_contains 'feature_head from lane' 'Step 4 fallback references the cached feature_head'
# Lane state must persist feature_head so the fallback squash can find it.
assert_contains '`feature_head`' 'lane state persists feature_head'
# Cleanup step must be worktree-only — the fallback has no worktree to remove.
assert_contains '# Worktree mode only:' 'Step 4 cleanup is gated on worktree mode'

# A3 — CHANGES_REQUESTED rework prompts must honour the worktree_failed flag
# (previously they always inlined WORKTREE_CTX, which broke fallback mode).
# The doc must contain the conditional include line *somewhere* — covers
# both the initial-launch tester/developer and the rework re-invocations.
if [ "$(grep -cF 'Include WORKTREE_CTX if WORKTREE_FAILED=false, else REPO_CTX with `worktree_failed: true`' "$FILE")" -ge 4 ]; then
    _pass 'rework prompts also use the WORKTREE_CTX / REPO_CTX conditional'
else
    _fail 'rework prompts also use the WORKTREE_CTX / REPO_CTX conditional' \
        'expected at least 4 occurrences (2 initial-launch + 2 rework re-invocation)'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

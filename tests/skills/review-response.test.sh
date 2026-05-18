#!/usr/bin/env bash
# B4 regression: `review-response.md` Step 9 (workspace-NOT-a-git-repo path)
# must re-sync BOTH the tracker AND the plan into each affected repo.
#
# The plan re-sync was missing pre-B4 — an inter-gate `[a] Expand scope` flow
# could amend the workspace plan via `MODE: plan-amendment`, but Phase 7 only
# wrote the tracker back into the repo, leaving the per-repo plan copy frozen
# at the pre-amendment state. The next holistic review (or any human looking
# at the merged PR) would see a tracker referring to a plan section that
# doesn't exist in the repo's plan file.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="$REPO_ROOT/skills/dev-workflow/commands/review-response.md"

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
        _fail "$label" "must not appear in review-response.md: $needle"
    else
        _pass "$label"
    fi
}

# Step 9 workspace-not-a-git-repo branch must include the plan re-sync line
# (post-M-14 consumer migration — canonical per-workflow layout).
assert_contains 'Read `ai/<YYYY-MM-DD>-<work-item-id>/plan.md` (workspace)    → Write to `<REPO_PATH>/ai/<YYYY-MM-DD>-<work-item-id>/plan.md`' \
    'Step 9 non-git-workspace path re-syncs the plan file (canonical layout)'

# The tracker re-sync must still be there too.
assert_contains 'Read `ai/<YYYY-MM-DD>-<work-item-id>/tracker.md` (workspace) → Write to `<REPO_PATH>/ai/<YYYY-MM-DD>-<work-item-id>/tracker.md`' \
    'Step 9 non-git-workspace path re-syncs the tracker file (canonical layout)'

# The commit step must stage the per-workflow directory (which contains
# both the tracker AND the plan in the canonical M-14 layout).
assert_contains 'git -C "<REPO_PATH>" add ai/<YYYY-MM-DD>-<work-item-id>/' \
    'Step 9 non-git-workspace commit stages the canonical per-workflow dir'

# Negative: pre-M-14 legacy patterns (ai/tasks/, ai/plans/ as separate
# write-side targets) must not reappear in Step 9.
step9_block=$(awk '/^### Step 9/,/^---/' "$FILE")
if printf '%s' "$step9_block" | grep -qE '^git -C "<REPO_PATH>" add ai/tasks/$'; then
    _fail 'Step 9 drops legacy ai/tasks/ add line' \
        'legacy `git -C "<REPO_PATH>" add ai/tasks/` still present in Step 9 (M-14 regression)'
else
    _pass 'Step 9 drops legacy ai/tasks/ add line'
fi

# The rationale block must mention WHY the plan re-sync matters — captures
# the inter-gate amendment scenario that motivated the fix.
assert_contains 'MODE: plan-amendment' \
    'Step 9 explains the plan-amendment scenario'
assert_contains 'Plan Amendment — Ad-Hoc Round' \
    'Step 9 names the amendment section heading'

# Step 9 workspace-IS-git-repo branch must also stage the per-workflow dir.
step9_block=$(awk '/^### Step 9/,0' "$FILE")
git_repo_branch=$(printf '%s' "$step9_block" | awk '/\*\*If the workspace IS a git repo\*\*/,/\*\*If the workspace is NOT a git repo\*\*/')
if printf '%s' "$git_repo_branch" | grep -qF 'git add ai/<YYYY-MM-DD>-<work-item-id>/'; then
    _pass 'Step 9 git-repo branch stages the canonical per-workflow dir'
else
    _fail 'Step 9 git-repo branch stages the canonical per-workflow dir' \
        'expected `git add ai/<YYYY-MM-DD>-<work-item-id>/` in the workspace-IS-git-repo branch'
fi
# Negative — pre-M-14 legacy `git add ai/tasks/` must not reappear.
if printf '%s' "$git_repo_branch" | grep -qE '^git add ai/tasks/$'; then
    _fail 'Step 9 git-repo branch drops legacy ai/tasks/ add line' \
        'legacy `git add ai/tasks/` (no per-workflow dir) still present in the git-repo branch'
else
    _pass 'Step 9 git-repo branch drops legacy ai/tasks/ add line'
fi

# C3 — Phase 7 task filter is section-based, not content-based. Pre-C3 it
# matched on `Notes contains PR-comment:` which silently broadened the
# filter if the token ever appeared in another section.
assert_contains 'Only process task rows that live under a `## Amendments (PR Review Round <N>)` heading' \
    'Step 8 filter is section-based'
# Negative — the pre-C3 content-based filter must not reappear.
step8_block=$(awk '/^### Step 8 —/,/^### Step 8b —/' "$FILE")
if printf '%s' "$step8_block" | grep -qF '`Notes` column contains `PR-comment:`'; then
    _fail 'Step 8 drops the pre-C3 content-based filter' \
        "pre-C3 filter wording (\`Notes\` contains \`PR-comment:\`) still present"
else
    _pass 'Step 8 drops the pre-C3 content-based filter'
fi

# B3 — Phase 7 amendments must re-trigger T-TEST hardening so the new
# production code lands behind the 90% coverage gate (pre-B3, amendments
# reused the already-Done T-TEST row and shipped without re-hardening).
assert_contains '### Step 8b — Re-trigger Phase 5 hardening on affected repos' \
    'Step 8b re-triggers T-TEST hardening after Phase 7 amendments land'
assert_contains 'Status: ✅ Done' \
    'Step 8b gates re-trigger on T-TEST being ✅ Done'
assert_contains '✅ Done → 🔧 In Progress' \
    'Step 8b names the legal rework transition for T-TEST'
assert_contains 'commands/test.md' \
    'Step 8b invokes commands/test.md for the re-trigger'
# The workflow-metrics policy must be explicit — re-trigger does NOT re-stamp
# Test hardening started/completed (those record the first Phase 5 run; the
# Phase 7 re-trigger is recorded by PR review response completed instead).
assert_contains 'Workflow Metrics `Test hardening started` / `Test hardening completed`' \
    'Step 8b documents the workflow-metrics non-update policy'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

#!/usr/bin/env bash
# B2 regression: preflight runs AFTER Phase 2 (plan), not before Phase 1.
# Pre-B2, preflight was the first step of the pipeline and created feature
# branches in every known repo because the Planner had not yet identified
# the affected ones — every run produced orphan branches.
#
# Locks the cross-file contract:
#   SKILL.md pipeline order:   requirements → plan → preflight → develop
#   requirements.md:           no feature-branch prerequisite
#   plan.md:                   defers plan commit to preflight, points Next Phase at preflight
#   preflight.md:              requires Phase 2 complete; reads tracker's Repo Status; commits the plan
#   develop.md:                Phase 3 prerequisite mentions preflight after Phase 2
#   CLAUDE.md:                 Workflow Phases section names pre-flight after GATE #1
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

assert_contains() {
    local file="$1" needle="$2" label="$3"
    if grep -qF -- "$needle" "$file"; then _pass "$label"; else _fail "$label" "expected to find: $needle in $(basename "$file")"; fi
}
assert_not_contains() {
    local file="$1" needle="$2" label="$3"
    if grep -qF -- "$needle" "$file"; then _fail "$label" "must not contain: $needle"; else _pass "$label"; fi
}

SKILL="$REPO_ROOT/skills/dev-workflow/SKILL.md"
REQS="$REPO_ROOT/skills/dev-workflow/commands/requirements.md"
PLAN="$REPO_ROOT/skills/dev-workflow/commands/plan.md"
PREFLIGHT="$REPO_ROOT/skills/dev-workflow/commands/preflight.md"
DEVELOP="$REPO_ROOT/skills/dev-workflow/commands/develop.md"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
README_MD="$REPO_ROOT/README.md"

# --- 1. SKILL.md pipeline order. ------------------------------------------
assert_contains "$SKILL" '1. `requirements` → 2. `plan` → 3. `preflight` → 4. `develop`' \
    'SKILL.md Full Pipeline puts preflight after plan'
assert_not_contains "$SKILL" '1. `preflight` → 2. `requirements`' \
    'SKILL.md no longer puts preflight as step 1'
# Command table: preflight phase column is "2.5" (between Phase 2 and Phase 3).
assert_contains "$SKILL" '| `preflight` | `commands/preflight.md` | 2.5 |' \
    'SKILL.md command table phases preflight at 2.5'

# --- 2. requirements.md no longer requires a feature branch. --------------
assert_contains "$REQS" '**No feature branch is required.**' \
    'requirements.md states no feature branch is required'
assert_not_contains "$REQS" 'Feature branch exists and is checked out (run `preflight` first)' \
    'requirements.md drops the pre-B2 feature-branch prerequisite'

# --- 3. plan.md defers the plan commit and points at preflight. ----------
assert_contains "$PLAN" '### Plan Commit Deferred to Pre-flight' \
    'plan.md declares the plan commit is deferred to preflight'
assert_contains "$PLAN" 'Proceed to **Pre-flight**' \
    'plan.md Next Phase points at Pre-flight'
# The old "## Commit the Plan" heading in plan.md must be gone — that step
# moved to preflight.md.
assert_not_contains "$PLAN" '### Commit the Plan' \
    'plan.md no longer has its own ### Commit the Plan section'

# --- 4. preflight.md is rewritten for the new ordering. ------------------
assert_contains "$PREFLIGHT" '**Phase**: Pre-flight (runs between Phase 2 and Phase 3)' \
    'preflight.md declares the new phase position'
assert_contains "$PREFLIGHT" 'Phase 2 complete — plan and tracker exist' \
    'preflight.md requires Phase 2 complete'
assert_contains "$PREFLIGHT" 'tracker'"'"'s `## Repo Status` section' \
    'preflight.md reads affected repos from the tracker Repo Status'
# The pre-B2 "ALL known repos as a safe default" path must be explicitly forbidden.
assert_contains "$PREFLIGHT" 'Do **NOT** fall back to "create branches in every known repo as a safe default"' \
    'preflight.md explicitly forbids the pre-B2 "all known repos" fallback'
# Plan commit step is now in preflight.
assert_contains "$PREFLIGHT" '### 3. Commit the Plan (single-repo workspace-is-git-repo case only)' \
    'preflight.md has the plan commit step'
assert_contains "$PREFLIGHT" '#<STORY-ID> #TPLAN: add approved implementation plan' \
    'preflight.md uses the canonical TPLAN commit subject'

# --- 5. develop.md prerequisites mention the new ordering. ---------------
assert_contains "$DEVELOP" 'Pre-flight complete — feature branches exist in every repo named in the tracker' \
    'develop.md prerequisites reference the new preflight position'

# --- 5b. E4: error message distinguishes "never ran" from "Planner failed".
assert_contains "$PREFLIGHT" 'no tracker found for story <id>' \
    'preflight.md surfaces a distinct error for the "no tracker" case'
assert_contains "$PREFLIGHT" 'has no `## Repo Status` section' \
    'preflight.md surfaces a distinct error for the "Planner failed mid-write" case'
assert_contains "$PREFLIGHT" 'isn'"'"'t in `repos-paths.md`' \
    'preflight.md surfaces a distinct error for the "repo not in repos-paths" case'

# --- 6. CLAUDE.md Workflow Phases names pre-flight after GATE #1. --------
assert_contains "$CLAUDE_MD" '*Pre-flight runs immediately after GATE #1 clears*' \
    'CLAUDE.md Workflow Phases names pre-flight position after GATE #1'

# --- 7. README sequence diagram updated (v2.0 phrasing). -----------------
# The v2.0 rewrite expresses the same constraint — preflight runs between P2
# and P3 — using the canonical phase label `P2.5 — Preflight`.
assert_contains "$README_MD" 'P2.5 — Preflight' \
    'README documents the P2.5 — Preflight phase label'
assert_contains "$README_MD" 'P2.5 Preflight' \
    'README flowchart renders the P2.5 Preflight node'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

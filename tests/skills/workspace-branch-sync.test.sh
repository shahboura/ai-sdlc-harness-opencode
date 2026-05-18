#!/usr/bin/env bash
# Workspace Branch Sync regression: at workflow entry, the orchestrator MUST
# ensure every repo in repos-paths.md is on its default branch with latest
# pulled BEFORE Phase 1 runs — and MUST prompt the human before switching
# branches when uncommitted changes are present.
#
# Pre-fix, Phase 1 / Phase 2 ran against whatever branch the workspace
# happened to be on. If that was a stale feature branch from a prior run,
# the Planner produced plans against stale code. Worse, the v1.x cached
# plugin had preflight BEFORE Phase 1, which created feature branches in
# every known repo regardless of plan scope.
#
# Locks the cross-file contract:
#   SKILL.md:        has "## Workspace Branch Sync" section with when-to-run
#                    table, per-repo procedure, uncommitted-changes prompt,
#                    pull-failure handling, and skip-rules for migrate/resume/hotfix.
#   requirements.md: Prerequisites note that Workspace Branch Sync has run.
#   preflight.md:    Step 2 has a defensive uncommitted-changes check before
#                    its `git checkout DEFAULT` (covers direct-phase invocations
#                    where the entry sync did not run).
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
PREFLIGHT="$REPO_ROOT/skills/dev-workflow/commands/preflight.md"

# --- 1. SKILL.md has the Workspace Branch Sync section. -------------------
assert_contains "$SKILL" '## Workspace Branch Sync (workflow-entry precondition)' \
    'SKILL.md declares the Workspace Branch Sync section'
assert_contains "$SKILL" '### When to run' \
    'SKILL.md has a when-to-run subsection'
assert_contains "$SKILL" '### Procedure (per repo)' \
    'SKILL.md has a per-repo procedure subsection'
assert_contains "$SKILL" '### Uncommitted-changes prompt (mandatory)' \
    'SKILL.md has the mandatory uncommitted-changes prompt subsection'
assert_contains "$SKILL" '### Pull failures' \
    'SKILL.md documents pull-failure handling'

# --- 2. Skip rules: migrate / resume / hotfix never sync. -----------------
assert_contains "$SKILL" 'First positional argument is `migrate`' \
    'SKILL.md skip rule: migrate'
assert_contains "$SKILL" 'First positional argument is `resume`' \
    'SKILL.md skip rule: resume'
assert_contains "$SKILL" 'First positional argument is `hotfix`' \
    'SKILL.md skip rule: hotfix'

# --- 3. Run-vs-skip keys on tracker's Plan approved metric. ---------------
assert_contains "$SKILL" 'Tracker exists, `Plan approved` is `—` (unset)' \
    'SKILL.md keys "run sync" on unset Plan approved'
assert_contains "$SKILL" 'Tracker exists, `Plan approved` is a timestamp' \
    'SKILL.md keys "skip sync" on set Plan approved (past P2.5)'

# --- 4. Procedure: fetch + ff-only pull, never force, never silent switch.
assert_contains "$SKILL" 'pull --ff-only origin' \
    'SKILL.md uses --ff-only pull (no force, no rebase)'
assert_contains "$SKILL" 'EMIT_UNCOMMITTED_PROMPT_AND_WAIT' \
    'SKILL.md branches to the prompt path on dirty + non-default branch'

# --- 5. Uncommitted-changes prompt: 3 options [a]/[b]/[c]. ----------------
assert_contains "$SKILL" '[a] Stash → switch → pull' \
    'SKILL.md prompt option [a] is stash + switch + pull'
assert_contains "$SKILL" '[b] Skip this repo' \
    'SKILL.md prompt option [b] is skip-this-repo'
assert_contains "$SKILL" '[c] Abort the workflow' \
    'SKILL.md prompt option [c] is abort-workflow'
assert_contains "$SKILL" 'Never silently switch a branch when uncommitted changes are present' \
    'SKILL.md states the never-silent-switch invariant'

# --- 6. Pull failures: non-FF surfaces divergence; never force / rebase. --
assert_contains "$SKILL" 'do NOT force-pull, do NOT rebase, do NOT discard' \
    'SKILL.md forbids force-pull / rebase / discard on non-FF'

# --- 7. requirements.md Prerequisites references the sync. ---------------
assert_contains "$REQS" 'Workspace Branch Sync has run' \
    'requirements.md Prerequisites mentions Workspace Branch Sync'
assert_contains "$REQS" '[a] stash / [b] skip / [c] abort' \
    'requirements.md names the 3-choice prompt explicitly'

# --- 8. preflight.md has a defensive uncommitted-changes check. ----------
assert_contains "$PREFLIGHT" 'Defensive uncommitted-changes check' \
    'preflight.md has a defensive uncommitted-changes check before its checkout'
assert_contains "$PREFLIGHT" 'EMIT_UNCOMMITTED_PROMPT_AND_WAIT' \
    'preflight.md emits the same prompt format as SKILL.md on dirty + non-default'
# Preflight switched to --ff-only pull as part of this work.
assert_contains "$PREFLIGHT" 'pull --ff-only origin' \
    'preflight.md uses --ff-only pull (no force)'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

#!/usr/bin/env bash
# Doc-grep regression for commands/quick.md + quick.manifest.yaml (US-E01-004).
#
# Validates:
#   1. quick.md exists with the canonical CC-05.8 invariant section.
#   2. quick.manifest.yaml exists with Q phase_id and GATE-3.
#   3. QPhaseGuard is invoked at Step 2 (guard check).
#   4. Mode: quick and test-required: false appear in the tracker template.
#   5. quick-mode: true appears in the tracker template.
#   6. Phase 0+B reviewer sub-mode is declared (OQ-A1 resolution).
#   7. Invariants block Planner, Tester, and upgrade (I-1, I-2, CC-05.8).
#   8. Quick-Mode: true commit footer is required.
#   9. Clean abort path is documented.
#  10. SKILL.md commands table includes `quick`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QUICK_CMD="$REPO_ROOT/skills/dev-workflow/commands/quick.md"
QUICK_MANIFEST="$REPO_ROOT/skills/dev-workflow/commands/quick.manifest.yaml"
SKILL="$REPO_ROOT/skills/dev-workflow/SKILL.md"

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

# 1. Files exist
[ -f "$QUICK_CMD" ] && _pass "quick.md exists" || _fail "quick.md" "file not found"
[ -f "$QUICK_MANIFEST" ] && _pass "quick.manifest.yaml exists" || _fail "quick.manifest.yaml" "file not found"

# 2. Manifest has phase_id: Q and gate_id: GATE-3
assert_contains "$QUICK_MANIFEST" "phase_id: Q" "manifest declares phase_id: Q"
assert_contains "$QUICK_MANIFEST" "gate_id: GATE-3" "manifest declares gate_id: GATE-3"
assert_contains "$QUICK_MANIFEST" "ai-sdlc-developer" "manifest invokes developer"
assert_contains "$QUICK_MANIFEST" "ai-sdlc-reviewer" "manifest invokes reviewer"
assert_contains "$QUICK_MANIFEST" "quick-mode-config.md" "manifest reads quick-mode-config.md"

# 3. QPhaseGuard invoked
assert_contains "$QUICK_CMD" "q_phase_guard" "quick.md invokes q_phase_guard"
assert_contains "$QUICK_CMD" "Guard check" "quick.md has guard check step"

# 4. Mode: quick in tracker template
assert_contains "$QUICK_CMD" "Mode: quick" "quick.md tracker template has Mode: quick"
assert_contains "$QUICK_CMD" "test-required: false" "quick.md tracker template sets test-required: false"

# 5. quick-mode: true in tracker template
assert_contains "$QUICK_CMD" "quick-mode: true" "quick.md tracker template has quick-mode: true"

# 6. Phase 0+B reviewer sub-mode documented
assert_contains "$QUICK_CMD" "Phase 0+B" "quick.md documents Phase 0+B reviewer mode"
assert_contains "$QUICK_CMD" "Phase A" "quick.md references Phase A skip"
assert_contains "$QUICK_CMD" "SKIP" "quick.md explicitly skips Phase A"

# 7. CC-05.8 invariants block Planner + Tester + upgrade
assert_contains "$QUICK_CMD" "No Planner invocation" "quick.md invariant: no Planner"
assert_contains "$QUICK_CMD" "No Tester invocation" "quick.md invariant: no Tester"
assert_contains "$QUICK_CMD" "No mid-flow upgrade" "quick.md invariant: no upgrade"
assert_contains "$QUICK_CMD" "CC-05.8" "quick.md cites CC-05.8"
assert_contains "$QUICK_CMD" "QPhaseGuard.refuse_agent" "quick.md calls refuse_agent"
assert_contains "$QUICK_CMD" "QPhaseGuard.refuse_upgrade" "quick.md calls refuse_upgrade"

# 8. Quick-Mode: true commit footer required
assert_contains "$QUICK_CMD" "Quick-Mode: true" "quick.md requires Quick-Mode: true footer"

# 9. Clean abort documented
assert_contains "$QUICK_CMD" "Clean abort" "quick.md has clean abort step"
assert_contains "$QUICK_CMD" "tracker.aborted.md" "quick.md archives tracker on abort"
assert_contains "$QUICK_CMD" "worktree remove" "quick.md removes worktree on abort"

# 10. SKILL.md commands table lists quick
assert_contains "$SKILL" "| \`quick\`" "SKILL.md commands table lists quick"
assert_contains "$SKILL" "commands/quick.md" "SKILL.md points quick at commands/quick.md"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for f in "${fail_msgs[@]}"; do printf '  - %s\n' "$f" >&2; done
    exit 1
fi

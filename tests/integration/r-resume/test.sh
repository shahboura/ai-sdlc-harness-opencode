#!/usr/bin/env bash
# R resume — exercise the recovery-state marker round-trip end-to-end.
#
# Recovery is the phase that restores workflow state after a crash. Its
# correctness depends on the marker file at
# `.claude/context/.recovery-state.md` being:
#   1. written at every phase-exit / tracker-state / gate-prompt rotation
#      point (per `_recovery_state_writer.stamp_*` functions)
#   2. round-trip readable (`read_recovery_state`)
#   3. summarised by `resume_label` into a one-line hint the orchestrator
#      surfaces to the human
#
# This test drives a fixture workspace through each rotation point in
# turn, asserts the marker shape after each, and validates the resume
# hint reflects the latest state.
#
# Created by: dev-workflow-plan.md [M-12] [IMPL-12-06]
# Maps to: TEST-68 (R crash-recovery sequence).
# CC conventions applied: CC-06.1, CC-06.5, CC-08.1.
set -uo pipefail

WF_INTEGRATION_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" && pwd)/assert.sh"
. "$WF_INTEGRATION_LIB/workflow_fixture.sh"

# Python invocation helper — every test exercises the writer functions
# directly to bypass the orchestrator-side LLM hop.
_pyrun() {
    PYTHONPATH="$WF_REPO_ROOT/scripts" python3 -c "$1" "$@"
}

_marker_path() {
    printf '%s/.claude/context/.recovery-state.md' "$WF_WORKSPACE"
}

# ─── Phase-exit rotation ────────────────────────────────────────────────────

test_stamp_phase_exit_writes_marker() {
    PYTHONPATH="$WF_REPO_ROOT/scripts" python3 -c "
import sys
sys.path.insert(0, '$WF_REPO_ROOT/scripts')
from _recovery_state_writer import stamp_phase_exit
ok = stamp_phase_exit('$WF_WORKSPACE', 'P3', timestamp='2026-05-17 09:00 UTC')
print('ok' if ok else 'failed')
" >/dev/null

    local marker; marker="$(_marker_path)"
    if [ ! -f "$marker" ]; then
        _fail "marker file not created at $marker"
        return 1
    fi
    if ! grep -qE 'Last completed phase:\s*P3' "$marker"; then
        _fail "marker missing 'Last completed phase: P3'"
        return 1
    fi
    if ! grep -qF '2026-05-17 09:00 UTC' "$marker"; then
        _fail "marker missing canonical timestamp"
        return 1
    fi
}

# ─── Tracker-state rotation ─────────────────────────────────────────────────

test_stamp_tracker_state_captures_in_flight_tasks() {
    # Build a tracker with one task at 🔧 In Progress + one at ⏳ Pending.
    cat > "$WF_TRACKER_PATH" <<EOF
# Tracker — ${WF_STORY_ID}

Story: ${WF_STORY_ID}
Story-State: In Progress

## Tasks

| Task | Description | Repo | Status | test-required | Started | Green At | Completed | Review Rounds |
|---|---|---|---|---|---|---|---|---|
| T1 | first | repo | 🔧 In Progress | true | ${WF_TODAY} 08:00 UTC | — | — | 0 |
| T2 | second | repo | ⏳ Pending | true | — | — | — | 0 |

## Task Metrics

## Workflow Metrics

EOF
    PYTHONPATH="$WF_REPO_ROOT/scripts" python3 -c "
import sys
sys.path.insert(0, '$WF_REPO_ROOT/scripts')
from _recovery_state_writer import stamp_tracker_state
stamp_tracker_state('$WF_WORKSPACE', '$WF_TRACKER_PATH', timestamp='2026-05-17 09:10 UTC')
" >/dev/null

    local marker; marker="$(_marker_path)"
    if ! grep -qE 'In-flight tasks:.*T1' "$marker"; then
        _fail "marker missing in-flight task T1; content:\n$(cat "$marker")"
        return 1
    fi
    if grep -qE 'In-flight tasks:.*T2' "$marker"; then
        _fail "marker wrongly listed pending task T2 as in-flight"
        return 1
    fi
}

# ─── Gate-prompt rotation ───────────────────────────────────────────────────

test_stamp_gate_prompt_uses_distinct_label() {
    PYTHONPATH="$WF_REPO_ROOT/scripts" python3 -c "
import sys
sys.path.insert(0, '$WF_REPO_ROOT/scripts')
from _recovery_state_writer import stamp_gate_prompt
stamp_gate_prompt('$WF_WORKSPACE', 'GATE-3', timestamp='2026-05-17 09:30 UTC')
" >/dev/null

    local marker; marker="$(_marker_path)"
    if ! grep -qE 'Last completed phase:\s*gate-prompt:GATE-3' "$marker"; then
        _fail "gate-prompt rotation missing 'gate-prompt:GATE-3' label"
        return 1
    fi
}

# ─── Round-trip via read_recovery_state ─────────────────────────────────────

test_read_recovery_state_round_trips_phase_exit() {
    PYTHONPATH="$WF_REPO_ROOT/scripts" python3 -c "
import sys, json
sys.path.insert(0, '$WF_REPO_ROOT/scripts')
from _recovery_state_writer import stamp_phase_exit, read_recovery_state
stamp_phase_exit('$WF_WORKSPACE', 'P4', timestamp='2026-05-17 10:00 UTC')
state = read_recovery_state('$WF_WORKSPACE')
print(json.dumps(state))
" > /tmp/recovery-state.json
    local content
    content="$(cat /tmp/recovery-state.json)"
    rm -f /tmp/recovery-state.json
    if ! printf '%s' "$content" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
# read_recovery_state preserves the marker's canonical field names
# (title-case with spaces), not a normalised snake_case form.
assert d.get('Last completed phase') == 'P4', f'got {d}'
assert '2026-05-17' in d.get('Timestamp', ''), f'got {d}'
" 2>&1; then
        _fail "read_recovery_state did not round-trip: $content"
        return 1
    fi
}

# ─── resume_label produces a human-readable hint ────────────────────────────

test_resume_label_summarises_marker() {
    PYTHONPATH="$WF_REPO_ROOT/scripts" python3 -c "
import sys
sys.path.insert(0, '$WF_REPO_ROOT/scripts')
from _recovery_state_writer import stamp_phase_exit, resume_label
stamp_phase_exit('$WF_WORKSPACE', 'P3', timestamp='2026-05-17 11:00 UTC')
print(resume_label('$WF_WORKSPACE'))
" > /tmp/resume-label.txt
    local label
    label="$(cat /tmp/resume-label.txt)"
    rm -f /tmp/resume-label.txt
    if [ -z "$label" ]; then
        _fail "resume_label returned empty string"
        return 1
    fi
    # Per the writer's docstring the label must reference the last phase.
    if ! printf '%s' "$label" | grep -qE 'P3'; then
        _fail "resume_label does not reference last phase (P3); got: $label"
        return 1
    fi
}

# ─── Marker absence: read returns None gracefully ───────────────────────────

test_read_recovery_state_returns_none_when_marker_absent() {
    # Fresh fixture has no marker. read_recovery_state must not crash.
    local result
    result=$(PYTHONPATH="$WF_REPO_ROOT/scripts" python3 -c "
import sys
sys.path.insert(0, '$WF_REPO_ROOT/scripts')
from _recovery_state_writer import read_recovery_state
state = read_recovery_state('$WF_WORKSPACE')
print('None' if state is None else 'NotNone')
")
    if [ "$result" != "None" ]; then
        _fail "expected None on absent marker, got: $result"
        return 1
    fi
}

run_workflow_tests

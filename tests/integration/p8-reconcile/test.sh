#!/usr/bin/env bash
# P8 reconcile — exercise the Done → Archived FSM transition and the
# Workflow-completed metric stamp end-to-end against a fixture tracker.
#
# Specifically asserts:
#   1. tracker-transition-guard hook ALLOWS `Done → Archived` (per FSM in
#      agents/shared/tracker-transition-rules.md row 3).
#   2. tracker-transition-guard hook REJECTS forbidden post-Archived
#      transitions (e.g. Archived → Done) — closes the gap where a faulty
#      reconcile flow attempts a back-transition.
#   3. After the canonical reconcile sequence (Story-State + per-task
#      Status both flipped to Archived, `Workflow completed` metric
#      stamped), the tracker passes its post-reconcile shape check.
#
# Created by: dev-workflow-plan.md [M-12] [IMPL-12-05]
# Maps to: TEST-67 (P8 reconcile flow end-to-end).
# CC conventions applied: CC-06.1, CC-06.5, CC-08.1.
set -uo pipefail

WF_INTEGRATION_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" && pwd)/assert.sh"
. "$WF_INTEGRATION_LIB/workflow_fixture.sh"

HOOK="$WF_REPO_ROOT/scripts/tracker-transition-guard.sh"

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Build a PreToolUse Edit-style payload for the hook. The hook reads
# tool_name + tool_input.file_path + tool_input.old_string + tool_input.new_string.
_mk_edit_payload() {
    local file_path="$1"
    local old_string="$2"
    local new_string="$3"
    python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'Edit',
    'tool_input': {
        'file_path': sys.argv[1],
        'old_string': sys.argv[2],
        'new_string': sys.argv[3],
    },
}))" "$file_path" "$old_string" "$new_string"
}

# Write a tracker pre-positioned for reconcile: Story-State Done + a single
# task at ✅ Done.
_setup_reconcile_ready_tracker() {
    cat > "$WF_TRACKER_PATH" <<EOF
# Tracker — ${WF_STORY_ID}

Story: ${WF_STORY_ID}
Story-State: Done
Workflow-Dir: ai/${WF_TODAY}-${WF_STORY_ID}/

## Tasks

| Task | Description | Repo | Status | test-required | Started | Green At | Completed | Review Rounds |
|---|---|---|---|---|---|---|---|---|
| T1 | example task | repo | ✅ Done | true | ${WF_TODAY} 09:00 UTC | ${WF_TODAY} 10:00 UTC | ${WF_TODAY} 10:30 UTC | 1 |

## Task Metrics

## Workflow Metrics

Bootstrap completed: ${WF_TODAY} 00:00 UTC
Development started: ${WF_TODAY} 08:00 UTC
Initial development completed: ${WF_TODAY} 11:00 UTC
PR created: ${WF_TODAY} 11:30 UTC

EOF
}

# ─── Allowed: Done → Archived (the canonical P8 transition) ─────────────────

test_done_to_archived_story_state_allowed() {
    _setup_reconcile_ready_tracker
    local payload
    payload="$(_mk_edit_payload "$WF_TRACKER_PATH" 'Story-State: Done' 'Story-State: Archived')"
    local rc
    rc=$(printf '%s' "$payload" | (cd "$WF_WORKSPACE" && "$HOOK") >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "tracker-transition-guard rejected Story-State: Done → Archived (rc=$rc); per FSM this must be allowed at P8"
        return 1
    fi
}

test_done_to_archived_per_task_status_allowed() {
    _setup_reconcile_ready_tracker
    local payload
    payload="$(_mk_edit_payload "$WF_TRACKER_PATH" \
        '| T1 | example task | repo | ✅ Done | true |' \
        '| T1 | example task | repo | 📦 Archived | true |')"
    local rc
    rc=$(printf '%s' "$payload" | (cd "$WF_WORKSPACE" && "$HOOK") >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "tracker-transition-guard rejected task ✅ Done → 📦 Archived (rc=$rc)"
        return 1
    fi
}

# ─── Forbidden: Archived → Done at the task-row level ──────────────────────
# Note on scope: the hook enforces the FSM against emoji-marked Status cells
# in the Tasks table — NOT against the plain-text `Story-State:` header
# field at the top of the tracker. Story-State transitions are
# orchestrator-trusted (governed by reconcile.md, hotfix.md, etc.) and not
# hook-enforced. This gap is documented below.

test_archived_to_done_per_task_status_forbidden() {
    _setup_reconcile_ready_tracker
    # First archive the task row (this is the precondition); then try to
    # revert. The hook MUST block this — Hotfix re-entry per M-19 operates
    # on a clone of the archived row, never resurrects the original.
    awk '{ gsub(/✅ Done/, "📦 Archived"); print }' \
        "$WF_TRACKER_PATH" > "$WF_TRACKER_PATH.tmp"
    mv "$WF_TRACKER_PATH.tmp" "$WF_TRACKER_PATH"
    local payload
    payload="$(_mk_edit_payload "$WF_TRACKER_PATH" \
        '| T1 | example task | repo | 📦 Archived | true |' \
        '| T1 | example task | repo | ✅ Done | true |')"
    local result rc
    result="$(printf '%s' "$payload" | (cd "$WF_WORKSPACE" && "$HOOK") 2>&1)"
    rc=$?
    if [ "$rc" = "0" ]; then
        _fail "tracker-transition-guard allowed forbidden task 📦 Archived → ✅ Done; should block (Hotfix must operate on a clone per M-19)"
        return 1
    fi
}

test_story_state_enforcement_is_orchestrator_trusted_not_hook_enforced() {
    # Document the scope: the hook does NOT enforce Story-State transitions
    # (no emoji marker on that field). A reconcile.md / hotfix.md violation
    # would slip past the hook and rely on orchestrator-side discipline.
    # This is acknowledged scope per the hook header comment in
    # `_tracker_transition_guard.py`.
    _setup_reconcile_ready_tracker
    awk '{ gsub(/Story-State: Done/, "Story-State: Archived"); print }' \
        "$WF_TRACKER_PATH" > "$WF_TRACKER_PATH.tmp"
    mv "$WF_TRACKER_PATH.tmp" "$WF_TRACKER_PATH"
    local payload
    payload="$(_mk_edit_payload "$WF_TRACKER_PATH" 'Story-State: Archived' 'Story-State: Done')"
    local rc
    rc=$(printf '%s' "$payload" | (cd "$WF_WORKSPACE" && "$HOOK") >/dev/null 2>&1; echo $?)
    # Either the hook ignores Story-State (rc=0) or it blocks. Either is
    # acceptable for this test — what we're documenting is that the
    # orchestrator must NOT rely on the hook to catch Story-State drift.
    # We assert the hook does not CRASH (rc < 3).
    if [ "$rc" -ge 3 ]; then
        _fail "hook crashed on Story-State edit (rc=$rc); should degrade gracefully"
        return 1
    fi
}

# ─── Workflow completed metric stamps under Workflow Metrics ────────────────

test_workflow_completed_stamp_idempotent() {
    _setup_reconcile_ready_tracker
    wf_stamp_metric 'Workflow completed' "${WF_TODAY} 12:00 UTC"
    wf_assert_metric 'Workflow completed' '^[0-9]{4}-[0-9]{2}-[0-9]{2} 12:00 UTC$' || return 1
    # Re-stamp with a later time — must replace, not duplicate.
    wf_stamp_metric 'Workflow completed' "${WF_TODAY} 13:30 UTC"
    if [ "$(grep -c '^Workflow completed:' "$WF_TRACKER_PATH")" != "1" ]; then
        _fail "Workflow completed re-stamp produced duplicate lines ($(grep -c '^Workflow completed:' "$WF_TRACKER_PATH"))"
        return 1
    fi
    wf_assert_metric 'Workflow completed' '13:30 UTC' || return 1
}

# ─── End-to-end: full canonical reconcile sequence ──────────────────────────

test_canonical_reconcile_sequence_produces_archived_tracker() {
    _setup_reconcile_ready_tracker

    # Step 1: transition the story.
    awk '{ gsub(/Story-State: Done/, "Story-State: Archived"); print }' \
        "$WF_TRACKER_PATH" > "$WF_TRACKER_PATH.tmp"
    mv "$WF_TRACKER_PATH.tmp" "$WF_TRACKER_PATH"

    # Step 2: archive the tasks.
    awk '{ gsub(/✅ Done/, "📦 Archived"); print }' \
        "$WF_TRACKER_PATH" > "$WF_TRACKER_PATH.tmp"
    mv "$WF_TRACKER_PATH.tmp" "$WF_TRACKER_PATH"

    # Step 3: stamp the completion metric.
    wf_stamp_metric 'Workflow completed' "${WF_TODAY} 12:00 UTC"

    # Now assert the post-reconcile shape.
    wf_assert_tracker_field 'Story-State' '^Archived$' || return 1
    wf_assert_metric 'Workflow completed' '^[0-9]{4}-' || return 1
    if grep -qE 'Story-State: Done' "$WF_TRACKER_PATH"; then
        _fail "reconcile sequence left Story-State: Done in tracker"
        return 1
    fi
    if grep -qE '✅ Done' "$WF_TRACKER_PATH"; then
        _fail "reconcile sequence left per-task ✅ Done in tracker"
        return 1
    fi
    if ! grep -qE '📦 Archived' "$WF_TRACKER_PATH"; then
        _fail "reconcile sequence did not produce per-task 📦 Archived"
        return 1
    fi
}

run_workflow_tests

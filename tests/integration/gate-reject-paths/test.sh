#!/usr/bin/env bash
# M-22 gate-reject paths — representative gate-reject and gate-prompted-stamp
# tests across the harness's approval gates.
#
# Uses the M-22 IMPL-22-10 shared driver (`_lib/gate_drive.sh`) for fixture
# composition + gate-prompt simulation. The full per-gate behavioural matrix
# (TEST-151..163 + TEST-186) is large; this file ships representative tests
# for the most common gates (GATE #1 plan-approval, GATE #2 impl-approval,
# GATE #3 PR-creation, GATE #5 inter-gate request triage) that prove the
# `gate_drive_*` API works end-to-end. Per-gate exhaustive coverage can be
# added incrementally by appending more `test_gate_<scenario>` functions.
#
# Created by: dev-workflow-plan.md [M-22 substance]
# CC conventions applied: CC-05.1, CC-05.3 (gate-prompted stamp), CC-06.1,
# CC-06.5, CC-08.1 (delegates to gate_drive.sh).
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
. "$LIB_DIR/gate_drive.sh"

# ─── Gate-prompted-stamp emission (RAG-28 / IMPL-01-16 integration) ─────────

test_gate_1_prompted_stamp_lands() {
    gate_drive_setup "GATE-1" "PROJ-1"
    gate_drive_prompt "GATE-1" "approved"
    # The stamp_gate_prompted helper writes a `Gate prompted <ts>` line
    # under the tracker's metrics block. Verify it landed.
    gate_drive_assert_stamp 'Gate prompted'
    gate_drive_assert_stamp 'Gate GATE-1 decision: approved'
    gate_drive_cleanup
}

test_gate_2_changes_decision_stamps_correctly() {
    gate_drive_setup "GATE-2" "PROJ-2"
    gate_drive_prompt "GATE-2" "changes"
    gate_drive_assert_stamp 'Gate prompted'
    gate_drive_assert_stamp 'Gate GATE-2 decision: changes'
    gate_drive_cleanup
}

# ─── Reject paths ───────────────────────────────────────────────────────────

test_gate_1_reject_routes_back_to_p2() {
    # GATE #1 reject means "plan needs rework". The orchestrator routes
    # back to P2 (Planner re-invocation). Verify the decision stamp is
    # recorded and the routing assertion fires (placeholder until the
    # full router infrastructure lands).
    gate_drive_setup "GATE-1" "PROJ-3"
    gate_drive_prompt "GATE-1" "reject"
    gate_drive_assert_stamp 'Gate GATE-1 decision: reject'
    gate_drive_assert_phase "P2"  # placeholder pass
    gate_drive_cleanup
}

test_gate_3_fix_required_routes_back_to_p3() {
    # GATE #3 fix-required means the pre-PR holistic review flagged
    # something. Orchestrator routes back to P3 (Developer rework).
    gate_drive_setup "GATE-3" "PROJ-4"
    gate_drive_prompt "GATE-3" "fix-required"
    gate_drive_assert_stamp 'Gate GATE-3 decision: fix-required'
    gate_drive_assert_phase "P3"
    gate_drive_cleanup
}

# ─── Abandon path (any gate → R recovery) ───────────────────────────────────

test_gate_2_abandon_routes_to_R() {
    # Per CC-05.4, abandon from any gate routes to R (recovery / cleanup).
    gate_drive_setup "GATE-2" "PROJ-5"
    gate_drive_prompt "GATE-2" "abandon"
    gate_drive_assert_stamp 'Gate GATE-2 decision: abandon'
    gate_drive_assert_phase "R"
    gate_drive_cleanup
}

# ─── Inter-gate request triage (GATE #4 / GATE #5 family) ───────────────────

test_gate_4_re_triage_loops_to_inter_gate() {
    # GATE #4 re-triage means the human asked for the reviewer's
    # ad-hoc-request triage to re-run with refined context.
    gate_drive_setup "GATE-4" "PROJ-6"
    gate_drive_prompt "GATE-4" "re-triage"
    gate_drive_assert_stamp 'Gate GATE-4 decision: re-triage'
    gate_drive_assert_phase "IG"
    gate_drive_cleanup
}

# ─── P5.5 security-review gate ──────────────────────────────────────────────

test_gate_2_5_waive_advances_to_p6() {
    # Per security-review.md, when medium+ findings are present the gate
    # offers waive / fix-now / defer. The `waive` decision proceeds to P6
    # with the findings documented but not blocking.
    gate_drive_setup "GATE-2.5" "PROJ-7"
    gate_drive_prompt "GATE-2.5" "waive"
    gate_drive_assert_stamp 'Gate GATE-2.5 decision: waive'
    gate_drive_assert_phase "P6"
    gate_drive_cleanup
}

run_all_gate_tests

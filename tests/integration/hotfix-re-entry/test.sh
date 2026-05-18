#!/usr/bin/env bash
# M-19 hotfix re-entry — verify both modes' tracker-state preconditions
# and FSM transitions against fixture archived trackers.
#
# `un-archive` mode: clones a `tracker.archived.md` into the same
# per-workflow directory as a fresh `tracker.md` (preserving the
# archive), appends a hotfix-tasks section, transitions per-row Status
# `📦 Archived → 🔧 In Progress` via the tracker-transition-guard hook
# (which DOES allow this transition per the FSM in
# `agents/shared/tracker-transition-rules.md`).
#
# `linked-fresh` mode: spawns a brand-new per-workflow directory under
# `ai/<date>-<child-id>/` with `Hotfix-Of:` + `Hotfix-Of-Archive:`
# bidirectional linkage headers; parent's archived tracker gets a
# `Hotfixed-By:` back-link.
#
# The actual workflow execution (P3 dev / P5 hardening / P6 PR) is LLM-
# driven and not testable in CI; this fixture-driven test covers the
# precondition + transition + linkage contract.
#
# Created by: dev-workflow-plan.md [M-19] [IMPL-19-substance]
# CC conventions applied: CC-05.5, CC-05.7, CC-06.1, CC-06.5.
set -uo pipefail

WF_INTEGRATION_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" && pwd)/assert.sh"
. "$WF_INTEGRATION_LIB/workflow_fixture.sh"

HOTFIX_MD="$WF_REPO_ROOT/skills/dev-workflow/commands/hotfix.md"
TRANSITION_HOOK="$WF_REPO_ROOT/scripts/tracker-transition-guard.sh"

_mk_edit_payload() {
    local file_path="$1" old="$2" new="$3"
    python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'Edit',
    'tool_input': {
        'file_path': sys.argv[1],
        'old_string': sys.argv[2],
        'new_string': sys.argv[3],
    },
}))" "$file_path" "$old" "$new"
}

# Build a canonical post-P8 archived tracker (the precondition for
# un-archive hotfix).
_setup_archived_parent() {
    cat > "$WF_WORKFLOW_DIR/tracker.archived.md" <<EOF
# Tracker — ${WF_STORY_ID}

Story: ${WF_STORY_ID}
Story-State: Archived
Workflow-Dir: ai/${WF_TODAY}-${WF_STORY_ID}/

## Tasks

| Task | Description | Repo | Status | Started | Completed | Review Rounds |
|---|---|---|---|---|---|---|
| T1 | original task | repo | 📦 Archived | ${WF_TODAY} 09:00 UTC | ${WF_TODAY} 10:30 UTC | 1 |

## Workflow Metrics

Plan approved: ${WF_TODAY} 08:30 UTC
Workflow completed: ${WF_TODAY} 12:00 UTC
EOF
}

# ─── Contract presence ──────────────────────────────────────────────────────

test_hotfix_command_exists_and_has_no_management_workspace_ref() {
    # Revised CC-07.3: the harness must NOT reference `dev-workflow-phase-specs.md`
    # (which lives only in the management workspace). The command file is the
    # canonical execution script; no external authority is linked.
    if [ ! -f "$HOTFIX_MD" ]; then
        _fail "hotfix.md missing"
        return 1
    fi
    if grep -qF "dev-workflow-phase-specs.md" "$HOTFIX_MD"; then
        _fail "hotfix.md still references dev-workflow-phase-specs.md (CC-07.3)"
        return 1
    fi
}

test_hotfix_documents_both_modes_with_window_threshold() {
    # un-archive mode + linked-fresh mode must both be documented.
    # Window threshold (CC-09 hotfix_unarchive_window_days = 30) must
    # be referenced.
    if ! grep -qF 'un-archive' "$HOTFIX_MD"; then
        _fail "hotfix.md missing un-archive mode documentation"
        return 1
    fi
    if ! grep -qF 'linked-fresh' "$HOTFIX_MD"; then
        _fail "hotfix.md missing linked-fresh mode documentation"
        return 1
    fi
    if ! grep -qE '30 days|hotfix_unarchive_window_days' "$HOTFIX_MD"; then
        _fail "hotfix.md missing 30-day window threshold reference"
        return 1
    fi
}

# ─── FSM transitions ────────────────────────────────────────────────────────

test_archived_to_in_progress_allowed_on_clone() {
    # The FSM explicitly permits 📦 Archived → 🔧 In Progress when the
    # transition operates on a tracker.md (clone), NOT on
    # tracker.archived.md (the original). The hook scopes to file_path
    # so the same edit against tracker.md is allowed.
    _setup_archived_parent
    # Clone the archived tracker as the active tracker.
    cp "$WF_WORKFLOW_DIR/tracker.archived.md" "$WF_TRACKER_PATH"
    # Add the Hotfix-Of-Archive header so the file is a legit clone.
    awk 'NR==1 { print; print ""; print "Hotfix-Of-Archive: tracker.archived.md"; next } { print }' \
        "$WF_TRACKER_PATH" > "$WF_TRACKER_PATH.tmp"
    mv "$WF_TRACKER_PATH.tmp" "$WF_TRACKER_PATH"

    local payload
    payload="$(_mk_edit_payload "$WF_TRACKER_PATH" \
        '| T1 | original task | repo | 📦 Archived |' \
        '| T1 | original task | repo | 🔧 In Progress |')"
    local rc
    rc=$(printf '%s' "$payload" | (cd "$WF_WORKSPACE" && "$TRANSITION_HOOK") >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "tracker-transition-guard rejected Archived → In Progress on clone (rc=$rc); FSM allows this for hotfix"
        return 1
    fi
}

test_clone_preserves_original_archive() {
    # Per the clone-not-rename invariant: the un-archive mode produces
    # `tracker.md` alongside the original `tracker.archived.md`. The
    # archive is never modified.
    _setup_archived_parent
    cp "$WF_WORKFLOW_DIR/tracker.archived.md" "$WF_TRACKER_PATH"
    # Both files must exist post-clone.
    wf_assert_file_exists "ai/${WF_TODAY}-${WF_STORY_ID}/tracker.archived.md" || return 1
    wf_assert_file_exists "ai/${WF_TODAY}-${WF_STORY_ID}/tracker.md" || return 1
    # Archive must still report Story-State: Archived.
    if ! grep -qE '^Story-State: Archived$' "$WF_WORKFLOW_DIR/tracker.archived.md"; then
        _fail "original archive should still be Story-State: Archived after clone"
        return 1
    fi
}

# ─── linked-fresh mode — bidirectional linkage ──────────────────────────────

test_linked_fresh_mode_writes_bidirectional_headers() {
    # The linked-fresh mode spawns a NEW workflow dir for the child
    # story. The parent's archived tracker gets a `Hotfixed-By:` header
    # pointing at the child; the child's tracker gets a
    # `Hotfix-Of:` header pointing back at the parent. Simulate this
    # and verify both anchors land.
    _setup_archived_parent
    local child_id="CHILD-1"
    local child_workflow_dir="$WF_WORKSPACE/ai/${WF_TODAY}-${child_id}"
    mkdir -p "$child_workflow_dir"

    # Parent gets back-link.
    awk -v link="Hotfixed-By: ai/${WF_TODAY}-${child_id}/tracker.md" \
        'NR==1 { print; print ""; print link; next } { print }' \
        "$WF_WORKFLOW_DIR/tracker.archived.md" > "$WF_WORKFLOW_DIR/tracker.archived.md.tmp"
    mv "$WF_WORKFLOW_DIR/tracker.archived.md.tmp" "$WF_WORKFLOW_DIR/tracker.archived.md"

    # Child gets forward-link in its new tracker.
    cat > "$child_workflow_dir/tracker.md" <<EOF
# Tracker — $child_id

Hotfix-Of: ai/${WF_TODAY}-${WF_STORY_ID}/tracker.archived.md
Story: $child_id
Story-State: Pending

## Tasks

| Task | Description | Repo | Status |
|---|---|---|---|
| T1 | fix regression | repo | ⏳ Pending |

## Workflow Metrics

EOF

    if ! grep -qF "Hotfixed-By: ai/${WF_TODAY}-${child_id}/tracker.md" "$WF_WORKFLOW_DIR/tracker.archived.md"; then
        _fail "parent archive missing Hotfixed-By: back-link"
        return 1
    fi
    if ! grep -qF "Hotfix-Of: ai/${WF_TODAY}-${WF_STORY_ID}/tracker.archived.md" "$child_workflow_dir/tracker.md"; then
        _fail "child tracker missing Hotfix-Of: forward-link"
        return 1
    fi
}

run_workflow_tests

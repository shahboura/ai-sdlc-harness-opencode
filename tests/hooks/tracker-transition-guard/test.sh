#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

HOOK="$(repo_root)/scripts/tracker-transition-guard.sh"

# Helper: build a minimal tracker with two task rows at given statuses.
mk_tracker() {
    local t1_status="$1"
    local t2_status="${2:-⏳ Pending}"
    cat <<EOF
# Story Tracker

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T1  | First task  | repoA | ${t1_status} | --    |
| T2  | Second task | repoA | ${t2_status} | --    |
EOF
}

# ── Legal transitions ───────────────────────────────────────────────────────

test_allow_pending_to_in_progress() {
    local path
    path="$(write_fixture 'ai/tasks/2026-05-tracker.md' "$(mk_tracker '⏳ Pending')")"
    local before='| T1  | First task  | repoA | ⏳ Pending | --    |'
    local after='| T1  | First task  | repoA | 🔧 In Progress | --    |'
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" "$before" "$after")"
}

test_allow_in_progress_to_in_review() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '🔧 In Progress')")"
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" \
        '| T1  | First task  | repoA | 🔧 In Progress | --    |' \
        '| T1  | First task  | repoA | 🔄 In Review | --    |')"
}

test_allow_in_review_to_done() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '🔄 In Review')")"
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" \
        '| T1  | First task  | repoA | 🔄 In Review | --    |' \
        '| T1  | First task  | repoA | ✅ Done | --    |')"
}

test_allow_in_review_to_in_progress_changes_requested() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '🔄 In Review')")"
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" \
        '| T1  | First task  | repoA | 🔄 In Review | --    |' \
        '| T1  | First task  | repoA | 🔧 In Progress | --    |')"
}

test_allow_done_to_in_progress_rework() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '✅ Done')")"
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" \
        '| T1  | First task  | repoA | ✅ Done | --    |' \
        '| T1  | First task  | repoA | 🔧 In Progress | --    |')"
}

# ── Illegal transitions ─────────────────────────────────────────────────────

test_block_pending_to_done_direct_skip() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending')")"
    assert_hook_blocks "$HOOK" \
        "$(mk_edit_payload "$path" \
            '| T1  | First task  | repoA | ⏳ Pending | --    |' \
            '| T1  | First task  | repoA | ✅ Done | --    |')" \
        "illegal status transition"
}

test_block_pending_to_in_review_skip() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending')")"
    assert_hook_blocks "$HOOK" \
        "$(mk_edit_payload "$path" \
            '| T1  | First task  | repoA | ⏳ Pending | --    |' \
            '| T1  | First task  | repoA | 🔄 In Review | --    |')" \
        "T1"
}

test_block_done_to_done_no_op_legal() {
    # Same-status writes are passes (no transition).
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '✅ Done')")"
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" \
        '| T1  | First task  | repoA | ✅ Done | --    |' \
        '| T1  | First task  | repoA | ✅ Done | newer notes |')"
}

# ── Multi-row edits (the previous regex missed these) ────────────────────────

test_block_multi_row_one_illegal() {
    # T1 goes Pending → In Progress (legal). T2 goes Pending → Done (ILLEGAL).
    # The old hook only validated the first emoji and let this through.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending' '⏳ Pending')")"
    local before_block='| T1  | First task  | repoA | ⏳ Pending | --    |
| T2  | Second task | repoA | ⏳ Pending | --    |'
    local after_block='| T1  | First task  | repoA | 🔧 In Progress | --    |
| T2  | Second task | repoA | ✅ Done | --    |'
    assert_hook_blocks "$HOOK" \
        "$(mk_edit_payload "$path" "$before_block" "$after_block")" \
        "T2"
}

test_allow_multi_row_all_legal() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending' '🔧 In Progress')")"
    local before='| T1  | First task  | repoA | ⏳ Pending | --    |
| T2  | Second task | repoA | 🔧 In Progress | --    |'
    local after='| T1  | First task  | repoA | 🔧 In Progress | --    |
| T2  | Second task | repoA | 🔄 In Review | --    |'
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" "$before" "$after")"
}

# ── MultiEdit coverage ──────────────────────────────────────────────────────

test_block_multiedit_illegal_in_second_edit() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending' '⏳ Pending')")"
    # First edit: T1 Pending → In Progress (legal).
    # Second edit: T2 Pending → Done (illegal — should still be caught).
    local edits='[
        {"old_string": "| T1  | First task  | repoA | ⏳ Pending | --    |", "new_string": "| T1  | First task  | repoA | 🔧 In Progress | --    |"},
        {"old_string": "| T2  | Second task | repoA | ⏳ Pending | --    |", "new_string": "| T2  | Second task | repoA | ✅ Done | --    |"}
    ]'
    assert_hook_blocks "$HOOK" \
        "$(mk_multiedit_payload "$path" "$edits")" \
        "T2"
}

test_allow_multiedit_all_legal() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending' '🔧 In Progress')")"
    local edits='[
        {"old_string": "| T1  | First task  | repoA | ⏳ Pending | --    |", "new_string": "| T1  | First task  | repoA | 🔧 In Progress | --    |"},
        {"old_string": "| T2  | Second task | repoA | 🔧 In Progress | --    |", "new_string": "| T2  | Second task | repoA | 🔄 In Review | --    |"}
    ]'
    assert_hook_allows "$HOOK" "$(mk_multiedit_payload "$path" "$edits")"
}

# ── Write coverage (whole-file rewrite) ─────────────────────────────────────

test_block_write_introduces_illegal_transition() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending')")"
    local new_content
    new_content="$(mk_tracker '🔄 In Review')"  # Pending → In Review = illegal skip
    assert_hook_blocks "$HOOK" \
        "$(mk_write_payload "$path" "$new_content")" \
        "T1"
}

test_allow_write_all_legal_transitions() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending')")"
    local new_content
    new_content="$(mk_tracker '🔧 In Progress')"
    assert_hook_allows "$HOOK" "$(mk_write_payload "$path" "$new_content")"
}

test_allow_write_new_tracker() {
    # File doesn't exist on disk — Write creating a fresh tracker has no
    # transitions to validate.
    local content
    content="$(mk_tracker '⏳ Pending')"
    assert_hook_allows "$HOOK" \
        "$(mk_write_payload "$FAKE_WORKSPACE/ai/tasks/brand-new.md" "$content")"
}

# ── Metadata-only edits should pass ─────────────────────────────────────────

test_allow_notes_column_edit() {
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '🔧 In Progress')")"
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" \
        '| T1  | First task  | repoA | 🔧 In Progress | --    |' \
        '| T1  | First task  | repoA | 🔧 In Progress | retried after build flake |')"
}

# ── Non-tracker paths pass through ──────────────────────────────────────────

test_allow_edit_non_tracker_file() {
    local path="$FAKE_WORKSPACE/src/foo.ts"
    mkdir -p "$(dirname "$path")"
    : > "$path"
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" 'a' 'b')"
}

test_allow_outside_workspace() {
    local payload
    payload="$(mk_edit_payload '/tmp/ai/tasks/x.md' \
        '| T1  | a | b | ⏳ Pending | -- |' \
        '| T1  | a | b | ✅ Done | -- |')"
    local rc
    rc=$(printf '%s' "$payload" | (cd /tmp && "$HOOK") >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0 outside workspace, got $rc"
        return 1
    fi
}

run_all_tests

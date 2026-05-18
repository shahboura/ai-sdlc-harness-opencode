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

# ── New rows added to an existing tracker ───────────────────────────────────

test_block_edit_inserts_new_row_already_done() {
    # Pre-existing tracker has T1 only. An Edit appends a brand-new T99 row
    # already marked ✅ Done — bypassing the entire workflow. Must block.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '🔧 In Progress')")"
    local before='| T2  | Second task | repoA | ⏳ Pending | --    |'
    local after='| T2  | Second task | repoA | ⏳ Pending | --    |
| T99 | Sneaky task | repoA | ✅ Done | --    |'
    assert_hook_blocks "$HOOK" \
        "$(mk_edit_payload "$path" "$before" "$after")" \
        "T99"
}

test_block_edit_inserts_new_row_in_progress() {
    # Same loophole, but the new row is "🔧 In Progress" — still illegal.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending')")"
    local before='| T2  | Second task | repoA | ⏳ Pending | --    |'
    local after='| T2  | Second task | repoA | ⏳ Pending | --    |
| T99 | New task | repoA | 🔧 In Progress | --    |'
    assert_hook_blocks "$HOOK" \
        "$(mk_edit_payload "$path" "$before" "$after")" \
        "T99"
}

test_allow_edit_inserts_new_row_pending() {
    # Phase 7: planner adds new task rows for accepted PR comments. They must
    # start as ⏳ Pending — and that's the legitimate path.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '✅ Done')")"
    local before='| T2  | Second task | repoA | ⏳ Pending | --    |'
    local after='| T2  | Second task | repoA | ⏳ Pending | --    |
| T-PR-1 | PR comment fix | repoA | ⏳ Pending | --    |'
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" "$before" "$after")"
}

# ── Ad-hoc Tasks section (inter-gate request handling) ─────────────────────
#
# Ad-hoc tasks live under a separate `## Ad-hoc Tasks (Batch <N>)` heading
# but use the same column schema and the same status lifecycle as the main
# table. The hook parses rows by Task ID + emoji regardless of which heading
# they sit under — so the same rules apply: new rows must start ⏳ Pending,
# and all standard transitions are legal. These fixtures lock that contract
# so a future refactor of the hook (e.g. a switch to section-aware parsing)
# does not accidentally break ad-hoc rows.

test_allow_edit_appends_adhoc_batch_with_pending_rows() {
    # Planner running MODE: ad-hoc-tasks appends a new section heading and a
    # row that must be born in ⏳ Pending. The Edit's `old_string` anchors on
    # the last line of the original tracker; the `new_string` is the same
    # line plus the appended ad-hoc section.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '✅ Done')")"
    local before='| T2  | Second task | repoA | ⏳ Pending | --    |'
    local after='| T2  | Second task | repoA | ⏳ Pending | --    |

## Ad-hoc Tasks (Batch 1)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T3  | Drawer close-on-Escape fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |'
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" "$before" "$after")"
}

test_block_edit_appends_adhoc_batch_with_done_row() {
    # Same loophole the main table closes — appending an ad-hoc row already
    # marked ✅ Done bypasses the entire workflow. Must block, regardless of
    # which heading the row sits under.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '✅ Done')")"
    local before='| T2  | Second task | repoA | ⏳ Pending | --    |'
    local after='| T2  | Second task | repoA | ⏳ Pending | --    |

## Ad-hoc Tasks (Batch 1)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T99 | Sneaky ad-hoc | repoA | ✅ Done | ad-hoc: [AHR-1] · source: gate-2 |'
    assert_hook_blocks "$HOOK" \
        "$(mk_edit_payload "$path" "$before" "$after")" \
        "T99"
}

test_block_edit_appends_adhoc_batch_with_in_progress_row() {
    # Same loophole, but the row is born 🔧 In Progress — also illegal.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending')")"
    local before='| T2  | Second task | repoA | ⏳ Pending | --    |'
    local after='| T2  | Second task | repoA | ⏳ Pending | --    |

## Ad-hoc Tasks (Batch 1)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T99 | Sneaky ad-hoc | repoA | 🔧 In Progress | ad-hoc: [AHR-1] · source: mid-phase |'
    assert_hook_blocks "$HOOK" \
        "$(mk_edit_payload "$path" "$before" "$after")" \
        "T99"
}

test_allow_adhoc_row_pending_to_in_progress() {
    # Once an ad-hoc row exists in the tracker, the orchestrator marches it
    # through the same lifecycle as a main-table row. Pending → In Progress
    # is the first transition.
    local content
    content="$(mk_tracker '✅ Done')

## Ad-hoc Tasks (Batch 1)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T3  | Drawer fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |"
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$content")"
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" \
        '| T3  | Drawer fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |' \
        '| T3  | Drawer fix | repoA | 🔧 In Progress | ad-hoc: [AHR-1] · source: gate-2 |')"
}

test_allow_adhoc_row_in_review_to_done() {
    # Reviewer approves the ad-hoc task — In Review → Done is legal.
    local content
    content="$(mk_tracker '✅ Done')

## Ad-hoc Tasks (Batch 1)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T3  | Drawer fix | repoA | 🔄 In Review | ad-hoc: [AHR-1] · source: gate-2 |"
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$content")"
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" \
        '| T3  | Drawer fix | repoA | 🔄 In Review | ad-hoc: [AHR-1] · source: gate-2 |' \
        '| T3  | Drawer fix | repoA | ✅ Done | ad-hoc: [AHR-1] · source: gate-2 |')"
}

test_block_adhoc_row_pending_to_done_skip() {
    # Same illegal-skip rule applies to ad-hoc rows — Pending → Done bypasses
    # the entire lifecycle.
    local content
    content="$(mk_tracker '✅ Done')

## Ad-hoc Tasks (Batch 1)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T3  | Drawer fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |"
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$content")"
    assert_hook_blocks "$HOOK" \
        "$(mk_edit_payload "$path" \
            '| T3  | Drawer fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |' \
            '| T3  | Drawer fix | repoA | ✅ Done | ad-hoc: [AHR-1] · source: gate-2 |')" \
        "T3"
}

test_allow_write_with_adhoc_section_all_pending() {
    # Whole-file Write that includes both the main table and an ad-hoc
    # section, all rows in legal starting states. The Planner in
    # MODE: ad-hoc-tasks may rewrite the tracker whole-file via Write — this
    # path must be allowed.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending')")"
    local new_content
    new_content="# Story Tracker

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T1  | First task  | repoA | 🔧 In Progress | --    |
| T2  | Second task | repoA | ⏳ Pending | --    |

## Ad-hoc Tasks (Batch 1)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T3  | Drawer fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |
"
    assert_hook_allows "$HOOK" "$(mk_write_payload "$path" "$new_content")"
}

test_block_write_with_adhoc_section_done_at_birth() {
    # Whole-file Write that introduces an ad-hoc row already ✅ Done.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '⏳ Pending')")"
    local new_content
    new_content="# Story Tracker

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T1  | First task  | repoA | ⏳ Pending | --    |
| T2  | Second task | repoA | ⏳ Pending | --    |

## Ad-hoc Tasks (Batch 1)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T99 | Sneaky ad-hoc | repoA | ✅ Done | ad-hoc: [AHR-1] · source: gate-2 |
"
    assert_hook_blocks "$HOOK" \
        "$(mk_write_payload "$path" "$new_content")" \
        "T99"
}

test_allow_multiedit_main_and_adhoc_rows() {
    # MultiEdit covering both the main table (Pending → In Progress for T1)
    # and an ad-hoc row (Pending → In Progress for T3). All legal.
    local content
    content="$(mk_tracker '⏳ Pending')

## Ad-hoc Tasks (Batch 1)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T3  | Drawer fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |"
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$content")"
    local edits='[
        {"old_string": "| T1  | First task  | repoA | ⏳ Pending | --    |", "new_string": "| T1  | First task  | repoA | 🔧 In Progress | --    |"},
        {"old_string": "| T3  | Drawer fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |", "new_string": "| T3  | Drawer fix | repoA | 🔧 In Progress | ad-hoc: [AHR-1] · source: gate-2 |"}
    ]'
    assert_hook_allows "$HOOK" "$(mk_multiedit_payload "$path" "$edits")"
}

# ── Interleaved sections: Amendments + Ad-hoc Tasks together ────────────────
#
# A long-lived story can accumulate both an `## Amendments (PR Review Round 1)`
# section (created in Phase 7) AND a `## Ad-hoc Tasks (Batch 1)` section
# (created inter-gate). The hook itself is **section-agnostic** — it parses
# any row matching `T<id>` + emoji regardless of which `##` heading sits
# above it (see scripts/_tracker_transition_guard.py — the parser walks
# every `|`-prefixed line in the file). These fixtures are NOT testing
# section-aware logic in the hook; they are **regression coverage** for the
# section-agnostic behaviour: ensuring that the presence of multiple section
# headings doesn't break row parsing, doesn't mask illegal transitions in
# the main table, and doesn't let a Done-at-birth row sneak in under a new
# section heading.
#
# If a future change adds genuine section-aware logic to the hook (e.g.
# "rows under `## Deferred Requests` are excluded from transition validation"),
# additional fixtures will need to be added — these existing five would
# still pass unchanged.

_interleaved_tracker() {
    # Tracker with main table (T1 ✅, T2 ✅), one Amendment row (T3 ✅), one
    # Ad-hoc row (T4 ⏳). Designed so that legal transitions land in each
    # section type independently.
    cat <<'EOF'
# Story Tracker

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T1  | Original feature   | repoA | ✅ Done | --    |
| T2  | Original migration | repoA | ✅ Done | --    |

## Amendments (PR Review Round 1)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T3  | Address PR feedback | repoA | ✅ Done | PR-comment: [PC-1] |

## Ad-hoc Tasks (Batch 1)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T4  | Drawer Escape-key fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |
EOF
}

test_allow_interleaved_adhoc_row_advances() {
    # The ad-hoc row T4 is ⏳ Pending alongside ✅ Done rows in the main and
    # Amendments sections. Advancing T4 to 🔧 In Progress must be allowed
    # without re-validating the already-done rows in other sections.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(_interleaved_tracker)")"
    assert_hook_allows "$HOOK" "$(mk_edit_payload "$path" \
        '| T4  | Drawer Escape-key fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |' \
        '| T4  | Drawer Escape-key fix | repoA | 🔧 In Progress | ad-hoc: [AHR-1] · source: gate-2 |')"
}

test_block_interleaved_amendment_row_skips() {
    # Trying to push an Amendment row that's already ✅ Done back into 🔄 In Review
    # is illegal (only ✅ Done → 🔧 In Progress is allowed for rework).
    # This tests that the hook treats Amendment rows by the same rules as main
    # rows, not "anything in a separate section is fair game."
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(_interleaved_tracker)")"
    assert_hook_blocks "$HOOK" \
        "$(mk_edit_payload "$path" \
            '| T3  | Address PR feedback | repoA | ✅ Done | PR-comment: [PC-1] |' \
            '| T3  | Address PR feedback | repoA | 🔄 In Review | PR-comment: [PC-1] |')" \
        "T3"
}

test_block_interleaved_append_second_adhoc_batch_done_at_birth() {
    # Tracker already has Batch 1 (T4 ⏳). The Planner runs MODE: ad-hoc-tasks
    # again to add Batch 2 (T5) — but T5 is born ✅ Done. The hook must catch
    # this even though the Edit spans the existing Batch 1 region and the new
    # Batch 2 region. Same loophole that would let a future round of any kind
    # of section append slip a Done row through.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(_interleaved_tracker)")"
    local before='| T4  | Drawer Escape-key fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |'
    local after='| T4  | Drawer Escape-key fix | repoA | ⏳ Pending | ad-hoc: [AHR-1] · source: gate-2 |

## Ad-hoc Tasks (Batch 2)

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T5  | Sneaky second-batch | repoA | ✅ Done | ad-hoc: [AHR-2] · source: gate-3 |'
    assert_hook_blocks "$HOOK" \
        "$(mk_edit_payload "$path" "$before" "$after")" \
        "T5"
}

test_allow_interleaved_write_with_all_sections_advancing() {
    # Whole-file Write rewriting the interleaved tracker: T4 advances ⏳ → 🔧,
    # rest stays put. The hook must parse all three sections, find the one
    # changed row, and allow the legal transition.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(_interleaved_tracker)")"
    local new_content
    new_content="$(_interleaved_tracker | sed 's/T4  | Drawer Escape-key fix | repoA | ⏳ Pending /T4  | Drawer Escape-key fix | repoA | 🔧 In Progress /')"
    assert_hook_allows "$HOOK" "$(mk_write_payload "$path" "$new_content")"
}

test_block_interleaved_write_main_done_to_inreview() {
    # Whole-file Write that introduces an illegal main-table transition while
    # leaving the Amendments and Ad-hoc sections untouched. Hook must still
    # catch the main-table violation — section-independent validation.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(_interleaved_tracker)")"
    # T1 jumps from ✅ Done → 🔄 In Review (illegal).
    local new_content
    new_content="$(_interleaved_tracker | sed 's/T1  | Original feature   | repoA | ✅ Done /T1  | Original feature   | repoA | 🔄 In Review /')"
    assert_hook_blocks "$HOOK" \
        "$(mk_write_payload "$path" "$new_content")" \
        "T1"
}

test_block_write_replaces_with_new_done_row() {
    # Whole-file Write that adds a new task row already marked ✅ Done.
    local path
    path="$(write_fixture 'ai/tasks/x.md' "$(mk_tracker '🔧 In Progress' '🔧 In Progress')")"
    local new_content
    new_content="# Story Tracker

| ID  | Description | Repo  | Status              | Notes |
|-----|-------------|-------|---------------------|-------|
| T1  | First task  | repoA | 🔧 In Progress | --    |
| T2  | Second task | repoA | 🔧 In Progress | --    |
| T99 | Sneaky task | repoA | ✅ Done | --    |
"
    assert_hook_blocks "$HOOK" \
        "$(mk_write_payload "$path" "$new_content")" \
        "T99"
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

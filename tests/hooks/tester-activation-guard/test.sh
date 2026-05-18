#!/usr/bin/env bash
# Hook: tester-activation-guard
# Event: SubagentStart on ai-sdlc-tester
# Policy: fail-CLOSED — block tester launch when the tracker state would
#         produce an invalid TDD or hardening run.
#
# Mode resolution:
#   - `--mode auto-tdd|auto-harden` argv flag (preferred, M-10 IMPL-10-01)
#   - `CLAUDE_SUBAGENT_PROMPT` env var keyword scan (legacy fallback)
#   - default: auto-harden (stricter)
#
# auto-tdd (Phase 3):    allow when ≥1 task has 🔧 In Progress status.
# auto-harden (Phase 5): allow only when EVERY T<n> dev task is ✅ Done.
#                        T-TEST-* rows are excluded from the check.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

HOOK="$(repo_root)/scripts/tester-activation-guard.sh"

# Each test starts with a clean ai/ tree under FAKE_WORKSPACE so leftover
# fixtures from prior tests don't bleed in (the hook walks the entire
# `ai/` subtree at startup).
_reset_ai() {
    rm -rf "$FAKE_WORKSPACE/ai"
}

mk_tracker() {
    # Build a tracker with two dev tasks at given statuses + one T-TEST row
    # that should be ignored by auto-harden checks.
    local t1_status="$1"
    local t2_status="${2:-⏳ Pending}"
    local t_test_status="${3:-⏳ Pending}"
    cat <<EOF
# Story Tracker

| ID         | Description    | Repo  | Status              | Notes |
|------------|----------------|-------|---------------------|-------|
| T1         | First task     | repoA | ${t1_status} | --    |
| T2         | Second task    | repoA | ${t2_status} | --    |
| T-TEST-RepoA | Phase 5 harden | repoA | ${t_test_status} | Phase 5 |
EOF
}

# ── no tracker → block ────────────────────────────────────────────────────

test_block_when_no_ai_directory() {
    _reset_ai
    local result rc stderr
    result="$(_run_hook "$HOOK" '{}')"
    rc="${result%%$'\t'*}"
    stderr="${result#*$'\t'}"
    if [ "$rc" != "2" ]; then
        _fail "expected exit 2 (block) with no ai/ tree, got $rc"
        return 1
    fi
    if ! printf '%s' "$stderr" | grep -qF 'BLOCKED'; then
        _fail "expected BLOCKED message in stderr; got: $stderr"
        return 1
    fi
}

test_block_when_ai_exists_but_no_tracker() {
    _reset_ai
    mkdir -p "$FAKE_WORKSPACE/ai/2026-05-18-S1"
    # Directory exists but lacks tracker.md
    assert_hook_blocks "$HOOK" '{}' 'No task tracker'
}

# ── auto-tdd mode (via CLAUDE_SUBAGENT_PROMPT env) ────────────────────────

test_auto_tdd_allow_when_in_progress_present() {
    _reset_ai
    write_fixture 'ai/2026-05-18-S1/tracker.md' "$(mk_tracker '🔧 In Progress' '⏳ Pending')" >/dev/null
    CLAUDE_SUBAGENT_PROMPT='@ai-sdlc-tester mode: auto-tdd run task T1' \
        assert_hook_allows "$HOOK" '{}'
}

test_auto_tdd_block_when_no_in_progress() {
    _reset_ai
    write_fixture 'ai/2026-05-18-S1/tracker.md' "$(mk_tracker '⏳ Pending' '⏳ Pending')" >/dev/null
    CLAUDE_SUBAGENT_PROMPT='@ai-sdlc-tester mode: auto-tdd' \
        assert_hook_blocks "$HOOK" '{}' 'BLOCKED (auto-tdd)'
}

# ── auto-harden mode (default + explicit) ─────────────────────────────────

test_auto_harden_allow_when_all_dev_tasks_done() {
    _reset_ai
    # T-TEST row is still Pending, which the hook must ignore.
    write_fixture 'ai/2026-05-18-S1/tracker.md' "$(mk_tracker '✅ Done' '✅ Done' '⏳ Pending')" >/dev/null
    CLAUDE_SUBAGENT_PROMPT='@ai-sdlc-tester mode: auto-harden' \
        assert_hook_allows "$HOOK" '{}'
}

test_auto_harden_block_when_some_dev_task_incomplete() {
    _reset_ai
    write_fixture 'ai/2026-05-18-S1/tracker.md' "$(mk_tracker '✅ Done' '🔧 In Progress')" >/dev/null
    CLAUDE_SUBAGENT_PROMPT='@ai-sdlc-tester mode: auto-harden' \
        assert_hook_blocks "$HOOK" '{}' 'BLOCKED (auto-harden)'
}

test_auto_harden_default_when_no_mode_signal() {
    # No `--mode` flag in argv (hook gets only the payload-file path) and no
    # `auto-tdd` / `auto-harden` keyword in CLAUDE_SUBAGENT_PROMPT → defaults
    # to auto-harden (the stricter check). With T2 not Done the block message
    # confirms which mode the hook resolved.
    _reset_ai
    write_fixture 'ai/2026-05-18-S1/tracker.md' "$(mk_tracker '✅ Done' '⏳ Pending')" >/dev/null
    unset CLAUDE_SUBAGENT_PROMPT
    assert_hook_blocks "$HOOK" '{}' 'auto-harden'
}

# ── schema-invalid trackers block with a clear message ────────────────────

test_block_when_status_column_missing() {
    _reset_ai
    # Header has no `Status` column — hook yields a __SCHEMA_ERROR__ tuple.
    write_fixture 'ai/2026-05-18-S1/tracker.md' '# tracker

| ID  | Description |
|-----|-------------|
| T1  | foo         |
' >/dev/null
    CLAUDE_SUBAGENT_PROMPT='@ai-sdlc-tester mode: auto-tdd' \
        assert_hook_blocks "$HOOK" '{}' 'schema invalid'
}

run_all_tests

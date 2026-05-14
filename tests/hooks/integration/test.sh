#!/usr/bin/env bash
# Integration smoke tests:
#   1. The two PreToolUse Bash hooks compose correctly when wired by
#      hooks.json — bash-write-guard runs first; if it blocks, the
#      commit-msg validator never runs.
#   2. Every untouched shell hook still loads and short-circuits cleanly
#      when fed an empty/irrelevant payload — proves nothing accidentally
#      broke during the lib refactor.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

GUARD="$(repo_root)/scripts/bash-write-guard.sh"
COMMIT="$(repo_root)/scripts/validate-commit-msg.sh"

# ── Composition ──────────────────────────────────────────────────────────────

test_compose_write_then_commit_blocks_at_first_hook() {
    # A command that BOTH writes to a sensitive file AND has a bad commit
    # message should be blocked by bash-write-guard first. We assert that
    # the guard blocks AND its stderr contains the sensitive-file message
    # (not the commit-msg help banner).
    local payload
    payload="$(mk_bash_payload 'git commit -m "missing ids" > .env.local')"
    local result rc stderr
    result="$(cd "$FAKE_WORKSPACE" && printf '%s' "$payload" | "$GUARD" 2>&1)"
    rc=$?
    if [ "$rc" != "2" ]; then
        _fail "bash-write-guard should block first; got rc=$rc"
        return 1
    fi
    if ! printf '%s' "$result" | grep -qF "sensitive file"; then
        _fail "expected sensitive-file message, got: $result"
        return 1
    fi
}

test_compose_clean_write_then_bad_commit_blocks_at_second_hook() {
    # No write violation, but bad commit message. bash-write-guard allows;
    # validate-commit-msg blocks.
    local payload
    payload="$(mk_bash_payload 'git commit -m "missing ids"')"
    local guard_rc commit_rc commit_stderr
    guard_rc=$(cd "$FAKE_WORKSPACE" && printf '%s' "$payload" | "$GUARD" >/dev/null 2>&1; echo $?)
    if [ "$guard_rc" != "0" ]; then
        _fail "bash-write-guard should allow; got rc=$guard_rc"
        return 1
    fi
    commit_stderr="$(cd "$FAKE_WORKSPACE" && printf '%s' "$payload" | "$COMMIT" 2>&1)"
    commit_rc=$?
    if [ "$commit_rc" != "2" ]; then
        _fail "validate-commit-msg should block; got rc=$commit_rc; stderr: $commit_stderr"
        return 1
    fi
}

test_compose_clean_command_passes_both() {
    local payload
    payload="$(mk_bash_payload 'git commit -m "#123 #T1: legitimate change"')"
    local guard_rc commit_rc
    guard_rc=$(cd "$FAKE_WORKSPACE" && printf '%s' "$payload" | "$GUARD" >/dev/null 2>&1; echo $?)
    commit_rc=$(cd "$FAKE_WORKSPACE" && printf '%s' "$payload" | "$COMMIT" >/dev/null 2>&1; echo $?)
    if [ "$guard_rc" != "0" ] || [ "$commit_rc" != "0" ]; then
        _fail "expected both hooks to allow; guard=$guard_rc commit=$commit_rc"
        return 1
    fi
}

# ── Regression smoke for untouched hooks ─────────────────────────────────────
#
# The lib refactor and bash-write-guard registration must not break any of
# the existing shell hooks. We feed each one its declared payload shape
# (or an empty one) and verify it exits 0 OR 2 — anything else (a syntax
# error in the script, for example) is a regression.

_smoke_hook() {
    local script="$1"
    local payload="$2"
    local rc
    rc=$(cd "$FAKE_WORKSPACE" && printf '%s' "$payload" | bash "$script" >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ] && [ "$rc" != "2" ]; then
        _fail "$script: unexpected rc=$rc on smoke payload"
        return 1
    fi
}

test_smoke_sensitive_file_guard() {
    _smoke_hook "$(repo_root)/scripts/sensitive-file-guard.sh" \
        '{"tool_name":"Write","tool_input":{"file_path":"/tmp/harmless.txt","content":"x"}}'
}

test_smoke_tracker_transition_guard() {
    _smoke_hook "$(repo_root)/scripts/tracker-transition-guard.sh" \
        '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/no-such-tracker.md","old_string":"a","new_string":"b"}}'
}

test_smoke_tracker_metrics_guard() {
    _smoke_hook "$(repo_root)/scripts/tracker-metrics-guard.sh" \
        '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/no-such.md","old_string":"a","new_string":"b"}}'
}

test_smoke_squash_merge_verify() {
    _smoke_hook "$(repo_root)/scripts/squash-merge-verify.sh" \
        '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
}

test_smoke_tracker_update_reminder() {
    _smoke_hook "$(repo_root)/scripts/tracker-update-reminder.sh" \
        '{"tool_name":"Agent","tool_input":{"prompt":"smoke"},"tool_response":""}'
}

test_smoke_agent_status_check() {
    _smoke_hook "$(repo_root)/scripts/agent-status-check.sh" \
        '{"tool_name":"Agent","tool_response":"some text\n\n📋 AGENT STATUS\nOutcome: SUCCESS\n"}'
}

test_smoke_tester_activation_guard() {
    _smoke_hook "$(repo_root)/scripts/tester-activation-guard.sh" \
        '{"subagent":"tester"}'
}

test_smoke_stop_failure_recovery() {
    _smoke_hook "$(repo_root)/scripts/stop-failure-recovery.sh" '{}'
}

run_all_tests

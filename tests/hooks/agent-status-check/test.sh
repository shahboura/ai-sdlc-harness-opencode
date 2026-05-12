#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

HOOK="$(repo_root)/scripts/agent-status-check.sh"

# Build SubagentStop payloads under various known key shapes.

mk_subagent_payload_response() {
    # tool_response is a plain string (the most common shape).
    local response="$1"
    python3 -c "
import json, sys
print(json.dumps({'response': sys.argv[1]}))
" "$response"
}

mk_subagent_payload_messages() {
    # No top-level 'response' — find the last assistant message in transcript.
    local response="$1"
    python3 -c "
import json, sys
print(json.dumps({
    'messages': [
        {'role': 'user', 'content': 'orchestrator prompt'},
        {'role': 'assistant', 'content': [{'type': 'text', 'text': sys.argv[1]}]},
    ]
}))
" "$response"
}

# ── Passes ──────────────────────────────────────────────────────────────────

test_allow_status_block_with_outcome() {
    local resp='Some prose.

📋 AGENT STATUS
Outcome: SUCCESS
Repo: x
Commit: abc
'
    assert_hook_allows "$HOOK" "$(mk_subagent_payload_response "$resp")"
}

test_allow_status_block_with_verdict() {
    local resp='Review done.

📋 AGENT STATUS
Verdict: APPROVED
'
    assert_hook_allows "$HOOK" "$(mk_subagent_payload_response "$resp")"
}

test_allow_status_block_from_messages_shape() {
    local resp='Final response.

📋 AGENT STATUS
Outcome: SUCCESS
'
    assert_hook_allows "$HOOK" "$(mk_subagent_payload_messages "$resp")"
}

# ── Blocks ──────────────────────────────────────────────────────────────────

test_block_no_status_block_at_all() {
    local resp='Just some prose, no status block to be found.'
    assert_hook_blocks "$HOOK" \
        "$(mk_subagent_payload_response "$resp")" \
        "does not contain the literal phrase"
}

test_block_status_block_without_outcome_or_verdict() {
    # The OLD hook would pass this — phrase present, but no required fields.
    local resp='Some prose.

📋 AGENT STATUS
(empty block, nothing here)
'
    assert_hook_blocks "$HOOK" \
        "$(mk_subagent_payload_response "$resp")" \
        "no Outcome: or Verdict: field"
}

test_block_status_block_mid_response_not_near_end() {
    # Phrase appears, but buried in prose. The OLD hook accepted this.
    local prose
    prose="$(printf 'mid-prose mention of 📋 AGENT STATUS in passing\nOutcome: SUCCESS\n'
             for i in $(seq 1 60); do printf 'more prose line %d\n' "$i"; done)"
    assert_hook_blocks "$HOOK" \
        "$(mk_subagent_payload_response "$prose")" \
        "not in the response's final"
}

# ── Fail-open paths ────────────────────────────────────────────────────────

test_allow_when_no_response_extractable() {
    # An unfamiliar payload shape should pass with a stderr warning,
    # not block every subagent stop.
    local payload='{"something": "completely different"}'
    assert_hook_allows "$HOOK" "$payload"
}

# ── Workspace gate ─────────────────────────────────────────────────────────

test_allow_outside_workspace() {
    local payload
    payload="$(mk_subagent_payload_response 'no status block')"
    local rc
    rc=$(printf '%s' "$payload" | (cd /tmp && "$HOOK") >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0 outside workspace, got $rc"
        return 1
    fi
}

# ── No /tmp debug artifact ──────────────────────────────────────────────────

test_no_tmp_debug_file_written() {
    # The OLD hook wrote /tmp/agent-status-debug.json on every invocation.
    # Make sure the rewrite doesn't.
    rm -f /tmp/agent-status-debug.json
    local resp='📋 AGENT STATUS
Outcome: SUCCESS
'
    printf '%s' "$(mk_subagent_payload_response "$resp")" | (cd "$FAKE_WORKSPACE" && "$HOOK") >/dev/null 2>&1
    if [ -f /tmp/agent-status-debug.json ]; then
        _fail "/tmp/agent-status-debug.json should not be written by the rewrite"
        rm -f /tmp/agent-status-debug.json
        return 1
    fi
}

run_all_tests

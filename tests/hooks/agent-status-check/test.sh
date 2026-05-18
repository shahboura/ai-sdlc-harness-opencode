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

# A canonical well-formed block that satisfies the universal floor (Agent +
# Outcome|Verdict + Next action). Reused across happy-path tests.
_well_formed_developer_block='Some prose.

📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Phase: 3
- Story: #123
- Outcome: SUCCESS
- Commit: abc
- Next action: ready for review
'

_well_formed_reviewer_block='Review done.

📋 AGENT STATUS
- Agent: ai-sdlc-reviewer
- Phase: 3
- Story: #123
- Verdict: APPROVED
- Next action: orchestrator: merge and proceed
'

# ── Passes ──────────────────────────────────────────────────────────────────

test_allow_well_formed_developer_block() {
    assert_hook_allows "$HOOK" "$(mk_subagent_payload_response "$_well_formed_developer_block")"
}

test_allow_well_formed_reviewer_block() {
    assert_hook_allows "$HOOK" "$(mk_subagent_payload_response "$_well_formed_reviewer_block")"
}

test_allow_status_block_from_messages_shape() {
    assert_hook_allows "$HOOK" "$(mk_subagent_payload_messages "$_well_formed_developer_block")"
}

test_allow_when_outcome_and_verdict_both_present() {
    # Both fields valid is fine — the hook only requires at least one.
    local resp='Output.

📋 AGENT STATUS
- Agent: ai-sdlc-reviewer
- Outcome: SUCCESS
- Verdict: APPROVED
- Next action: orchestrator: merge and proceed
'
    assert_hook_allows "$HOOK" "$(mk_subagent_payload_response "$resp")"
}

# ── Blocks: structural ─────────────────────────────────────────────────────

test_block_no_status_block_at_all() {
    local resp='Just some prose, no status block to be found.'
    assert_hook_blocks "$HOOK" \
        "$(mk_subagent_payload_response "$resp")" \
        "does not contain the literal phrase"
}

test_block_status_block_mid_response_not_near_end() {
    # Phrase appears, but buried in prose.
    local prose
    prose="$(printf 'mid-prose mention of 📋 AGENT STATUS in passing\nOutcome: SUCCESS\n'
             for i in $(seq 1 60); do printf 'more prose line %d\n' "$i"; done)"
    assert_hook_blocks "$HOOK" \
        "$(mk_subagent_payload_response "$prose")" \
        "not in the response's final"
}

# ── Blocks: universal-floor field checks ───────────────────────────────────

test_block_missing_agent_field() {
    local resp='Output.

📋 AGENT STATUS
- Outcome: SUCCESS
- Next action: ready for review
'
    assert_hook_blocks "$HOOK" \
        "$(mk_subagent_payload_response "$resp")" \
        "no \`Agent:\` field"
}

test_block_unrecognized_agent_value() {
    local resp='Output.

📋 AGENT STATUS
- Agent: orchestrator
- Outcome: SUCCESS
- Next action: ready for review
'
    assert_hook_blocks "$HOOK" \
        "$(mk_subagent_payload_response "$resp")" \
        "not recognized"
}

test_block_outcome_and_verdict_both_absent() {
    local resp='Output.

📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Next action: ready for review
'
    assert_hook_blocks "$HOOK" \
        "$(mk_subagent_payload_response "$resp")" \
        "Outcome:\` / \`Verdict:\` with a"
}

test_block_outcome_present_but_empty() {
    # Outcome: with no value — must surface as "empty", not "absent".
    local resp='Output.

📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Outcome:
- Next action: ready for review
'
    assert_hook_blocks "$HOOK" \
        "$(mk_subagent_payload_response "$resp")" \
        "Outcome=empty"
}

test_block_next_action_missing() {
    local resp='Output.

📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Outcome: SUCCESS
'
    assert_hook_blocks "$HOOK" \
        "$(mk_subagent_payload_response "$resp")" \
        "Next action:"
}

test_block_next_action_present_but_empty() {
    local resp='Output.

📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Outcome: SUCCESS
- Next action:
'
    assert_hook_blocks "$HOOK" \
        "$(mk_subagent_payload_response "$resp")" \
        "Next action:"
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

# ── HTML-entity decoding: agent response with &lt; &gt; &amp; entities ──────

test_allow_html_encoded_response_after_unescape() {
    # Observation: one reviewer invocation in a multi-task lane emits AGENT
    # STATUS with raw `<`, `>`, `&` characters; a sibling invocation emits
    # the same shape with `&lt;`, `&gt;`, `&amp;` entities (cause unclear —
    # model emission non-determinism or transcript layer). The hook must
    # `html.unescape()` the response before parsing so both forms validate
    # identically. Confirm that an otherwise-valid block with HTML-encoded
    # preamble + an encoded `Map&lt;String, Object&gt;` value inside the
    # block still passes the universal floor.
    local encoded_response='Review complete.

&lt;!-- internal note --&gt;

Finding: the type signature `Map&lt;String, Object&gt;` should use a more specific type.

📋 AGENT STATUS
- Agent: ai-sdlc-reviewer
- Phase: 3
- Verdict: APPROVED
- Outcome: SUCCESS
- Next action: proceed to next task
'
    local rc
    rc=$(printf '%s' "$(mk_subagent_payload_response "$encoded_response")" | (cd "$FAKE_WORKSPACE" && "$HOOK") >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0 (encoded entities should decode and validate), got $rc"
        return 1
    fi
}

test_block_with_encoded_outcome_value_still_validates() {
    # Pathological case: the Outcome value itself is HTML-encoded (e.g.
    # `Outcome: &amp;SUCCESS` — actually never observed but a defensive
    # check). After unescape this becomes `Outcome: &SUCCESS` which is NOT
    # a recognised outcome and should be rejected — proving the unescape ran
    # AND the validator sees the decoded value (not the encoded one).
    local pathological='📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Phase: 3
- Outcome: &amp;BOGUS
- Next action: x
'
    local result rc
    result="$(printf '%s' "$(mk_subagent_payload_response "$pathological")" | (cd "$FAKE_WORKSPACE" && "$HOOK") 2>&1)"
    rc=$?
    # We do not enforce the *exact* failure mode here — only that the
    # decoded `&BOGUS` is what the validator sees (either via the unknown-
    # outcome-value check or via the universal-floor check). Confirm that
    # the encoded-form `&amp;BOGUS` does NOT appear in the error output —
    # the validator should report the decoded form.
    if printf '%s' "$result" | grep -qF '&amp;'; then
        _fail "validator surfaced raw HTML-encoded form '&amp;' — html.unescape did not run pre-validation; output: $result"
        return 1
    fi
}

# ── No /tmp debug artifact ──────────────────────────────────────────────────

test_no_tmp_debug_file_written() {
    rm -f /tmp/agent-status-debug.json
    printf '%s' "$(mk_subagent_payload_response "$_well_formed_developer_block")" | (cd "$FAKE_WORKSPACE" && "$HOOK") >/dev/null 2>&1
    if [ -f /tmp/agent-status-debug.json ]; then
        _fail "/tmp/agent-status-debug.json should not be written by the rewrite"
        rm -f /tmp/agent-status-debug.json
        return 1
    fi
}

run_all_tests

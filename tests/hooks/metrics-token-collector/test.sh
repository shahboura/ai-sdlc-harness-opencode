#!/usr/bin/env bash
# Unit tests for scripts/_metrics_token_collector.py (IMPL-25-04 / US-E02-003).
#
# Validates the ADR-002 Path-A token-capture approach:
#   1. Valid transcript with usage blocks → aggregated counts written to .token-log.jsonl
#   2. Missing transcript → null-token line written (fail-open, CC-02.4.2)
#   3. Transcript with no usage blocks → null-token line written
#   4. Malformed JSONL lines → skipped; valid lines still counted
#   5. No active workflow dir → exits 0 silently (no crash)
#   6. session_id propagated into the JSONL record
#
# CC conventions validated: CC-02.4.2 (null-safe), ADR-002 (orchestrator-capture).

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

REPO_ROOT="$(repo_root)"
SCRIPT="$REPO_ROOT/scripts/_metrics_token_collector.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_run() {
    # Args forwarded directly to the Python script.
    _last_rc=0
    python3 "$SCRIPT" "$@" 2>/dev/null || _last_rc=$?
}

# Write a fake tracker.md inside FAKE_WORKSPACE/ai/<dir>/
_make_workflow_dir() {
    local dir_name="${1:-2026-05-20-STORY-001}"
    local wf="$FAKE_WORKSPACE/ai/$dir_name"
    mkdir -p "$wf"
    printf '# Tracker\n' > "$wf/tracker.md"
    # touch to ensure it has a recent mtime
    touch "$wf/tracker.md"
    printf '%s' "$wf"
}

# Write a fake transcript JSONL with N assistant messages each carrying usage.
_make_transcript() {
    local path="$1"
    local input="${2:-100}"
    local output="${3:-50}"
    local cache_read="${4:-200}"
    local cache_write="${5:-10}"
    local n_msgs="${6:-2}"
    local i
    for i in $(seq 1 "$n_msgs"); do
        python3 -c "
import json
print(json.dumps({
    'type': 'assistant',
    'message': {
        'usage': {
            'input_tokens': $input,
            'output_tokens': $output,
            'cache_read_input_tokens': $cache_read,
            'cache_creation_input_tokens': $cache_write,
        }
    }
}))
" >> "$path"
    done
}

_read_last_log_line() {
    local wf="$1"
    local log="$wf/.token-log.jsonl"
    [ -f "$log" ] && tail -1 "$log" || echo ""
}

_field() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('$key'); print(v if v is not None else '')"
}

# ---------------------------------------------------------------------------
# Test 1: Valid transcript aggregates token counts correctly
# ---------------------------------------------------------------------------

test_valid_transcript_writes_aggregated_counts() {
    local wf
    wf="$(_make_workflow_dir "2026-05-20-STORY-AGG")"
    local transcript="$FAKE_WORKSPACE/transcript_agg.jsonl"
    # 2 messages × (100 input, 50 output, 200 cache_read, 10 cache_write)
    _make_transcript "$transcript" 100 50 200 10 2

    _run --workspace "$FAKE_WORKSPACE" --transcript "$transcript" --session-id "sess-001"
    [ "$_last_rc" -eq 0 ] || { _fail "expected exit 0, got $_last_rc"; return; }

    local line
    line="$(_read_last_log_line "$wf")"
    [ -n "$line" ] || { _fail ".token-log.jsonl not written or empty"; return; }

    # 2 messages × 100 = 200 input tokens
    local ti
    ti="$(_field "$line" "tokens_input")"
    [ "$ti" = "200" ] || { _fail "expected tokens_input=200, got '$ti'"; return; }

    local to
    to="$(_field "$line" "tokens_output")"
    [ "$to" = "100" ] || { _fail "expected tokens_output=100, got '$to'"; return; }

    local tcr
    tcr="$(_field "$line" "tokens_cache_read")"
    [ "$tcr" = "400" ] || { _fail "expected tokens_cache_read=400, got '$tcr'"; return; }

    local tcw
    tcw="$(_field "$line" "tokens_cache_write")"
    [ "$tcw" = "20" ] || { _fail "expected tokens_cache_write=20, got '$tcw'"; return; }
}

# ---------------------------------------------------------------------------
# Test 2: Missing transcript → null tokens, no crash (CC-02.4.2)
# ---------------------------------------------------------------------------

test_missing_transcript_writes_null_tokens() {
    local wf
    wf="$(_make_workflow_dir "2026-05-20-STORY-NULL")"

    _run --workspace "$FAKE_WORKSPACE" --transcript "/nonexistent/transcript.jsonl" --session-id "sess-002"
    [ "$_last_rc" -eq 0 ] || { _fail "expected exit 0 for missing transcript, got $_last_rc"; return; }

    local line
    line="$(_read_last_log_line "$wf")"
    [ -n "$line" ] || { _fail ".token-log.jsonl not written for null-token case"; return; }

    # null tokens render as empty string (not 0, per CC-02.4.2)
    local ti
    ti="$(_field "$line" "tokens_input")"
    [ -z "$ti" ] || [ "$ti" = "None" ] || { _fail "expected null tokens_input, got '$ti'"; }
}

# ---------------------------------------------------------------------------
# Test 3: Transcript with no usage blocks → null tokens
# ---------------------------------------------------------------------------

test_transcript_no_usage_writes_null_tokens() {
    local wf
    wf="$(_make_workflow_dir "2026-05-20-STORY-NOUSAGE")"
    local transcript="$FAKE_WORKSPACE/transcript_no_usage.jsonl"
    # Write assistant messages without usage fields
    printf '{"type":"assistant","message":{"content":"hello"}}\n' >> "$transcript"
    printf '{"type":"user","message":{"content":"hi"}}\n' >> "$transcript"

    _run --workspace "$FAKE_WORKSPACE" --transcript "$transcript" --session-id "sess-003"
    [ "$_last_rc" -eq 0 ] || { _fail "expected exit 0, got $_last_rc"; return; }

    local line
    line="$(_read_last_log_line "$wf")"
    local ti
    ti="$(_field "$line" "tokens_input")"
    [ -z "$ti" ] || [ "$ti" = "None" ] || { _fail "expected null tokens_input for no-usage transcript, got '$ti'"; }
}

# ---------------------------------------------------------------------------
# Test 4: Malformed lines skipped; valid lines counted
# ---------------------------------------------------------------------------

test_malformed_lines_skipped_valid_counted() {
    local wf
    wf="$(_make_workflow_dir "2026-05-20-STORY-MALFORMED")"
    local transcript="$FAKE_WORKSPACE/transcript_malformed.jsonl"
    printf 'NOT JSON AT ALL\n' >> "$transcript"
    printf '{"type":"assistant","message":{"usage":{"input_tokens":77,"output_tokens":33,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$transcript"
    printf '{broken json\n' >> "$transcript"

    _run --workspace "$FAKE_WORKSPACE" --transcript "$transcript"
    [ "$_last_rc" -eq 0 ] || { _fail "expected exit 0 with malformed lines, got $_last_rc"; return; }

    local line
    line="$(_read_last_log_line "$wf")"
    local ti
    ti="$(_field "$line" "tokens_input")"
    [ "$ti" = "77" ] || { _fail "expected tokens_input=77 (valid line counted), got '$ti'"; }
}

# ---------------------------------------------------------------------------
# Test 5: No ai/ dir → exits 0 silently
# ---------------------------------------------------------------------------

test_no_workflow_dir_exits_silently() {
    # Use a workspace with no ai/ subdirectory
    local empty_ws
    empty_ws="$(mktemp -d -t toktest_noai.XXXXXX)"

    _run --workspace "$empty_ws" --transcript "/nonexistent.jsonl"
    [ "$_last_rc" -eq 0 ] || { _fail "expected exit 0 when no ai/ dir, got $_last_rc"; }
    rmdir "$empty_ws" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test 6: session_id propagated into JSONL record
# ---------------------------------------------------------------------------

test_session_id_propagated() {
    local wf
    wf="$(_make_workflow_dir "2026-05-20-STORY-SID")"
    local transcript="$FAKE_WORKSPACE/transcript_sid.jsonl"
    _make_transcript "$transcript" 10 5 0 0 1

    _run --workspace "$FAKE_WORKSPACE" --transcript "$transcript" --session-id "my-session-xyz"
    [ "$_last_rc" -eq 0 ] || { _fail "expected exit 0, got $_last_rc"; return; }

    local line
    line="$(_read_last_log_line "$wf")"
    local sid
    sid="$(_field "$line" "session_id")"
    [ "$sid" = "my-session-xyz" ] || { _fail "expected session_id=my-session-xyz, got '$sid'"; }
}

run_all_tests

#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

HOOK="$(repo_root)/scripts/tracker-update-reminder/../tracker-update-reminder.sh"
HOOK="$(repo_root)/scripts/tracker-update-reminder.sh"

# Helper: build a tracker, returning the path inside FAKE_WORKSPACE.
mk_test_tracker() {
    local t1_status="$1"
    local name="${2:-2026-05-12-story-123.md}"
    local content
    content="$(cat <<EOF
# Story Tracker

| ID  | Description | Status            | Notes |
|-----|-------------|-------------------|-------|
| T1  | First task  | ${t1_status} | --    |
EOF
)"
    write_fixture "ai/tasks/$name" "$content"
}

# Run the hook and capture stdout (the JSON additionalContext output).
_run_reminder() {
    local payload="$1"
    (
        cd "$FAKE_WORKSPACE"
        printf '%s' "$payload" | "$HOOK" 2>/dev/null
    )
}

# ── Developer SUCCESS — current=in_progress → reminder for in_review ────────

test_reminder_after_developer_success_when_tracker_still_in_progress() {
    mk_test_tracker '🔧 In Progress' >/dev/null
    local response
    response='Developer work complete.

📋 AGENT STATUS
Outcome: SUCCESS
Repo: repoA
Commit: deadbeef
'
    local payload
    payload="$(mk_agent_payload "$response" 'developer' 'Implement task T1 for story 123')"
    local out
    out="$(_run_reminder "$payload")"
    if [ -z "$out" ]; then
        _fail "expected reminder JSON, got empty"
        return 1
    fi
    if ! printf '%s' "$out" | grep -qF 'TRACKER UPDATE NEEDED'; then
        _fail "expected reminder text, got: $out"
        return 1
    fi
    # The output is JSON-encoded; emojis are escaped to \uXXXX. Match the
    # label text rather than the literal emoji to stay robust.
    if ! printf '%s' "$out" | grep -qF 'In Review'; then
        _fail "expected expected-state mention, got: $out"
        return 1
    fi
}

test_no_reminder_when_tracker_already_in_review() {
    mk_test_tracker '🔄 In Review' >/dev/null
    local response
    response='Developer done.

📋 AGENT STATUS
Outcome: SUCCESS
Task: T1
'
    local out
    out="$(_run_reminder "$(mk_agent_payload "$response" 'developer' 'task T1 of story 123')")"
    if [ -n "$out" ]; then
        _fail "expected no reminder, got: $out"
        return 1
    fi
}

# ── Reviewer APPROVED — current=in_review → reminder for done ──────────────

test_reminder_after_reviewer_approved() {
    mk_test_tracker '🔄 In Review' >/dev/null
    local response
    response='Spec compliance: PASS.

📋 AGENT STATUS
Verdict: APPROVED
Task: T1
'
    local out
    out="$(_run_reminder "$(mk_agent_payload "$response" 'reviewer' 'review task T1 of story 123')")"
    if [ -z "$out" ]; then
        _fail "expected reminder, got empty"
        return 1
    fi
    if ! printf '%s' "$out" | grep -qF 'Done'; then
        _fail "expected Done reminder, got: $out"
        return 1
    fi
}

# ── Reviewer CHANGES_REQUESTED — current=in_review → reminder for in_progress

test_reminder_after_reviewer_changes_requested() {
    mk_test_tracker '🔄 In Review' >/dev/null
    local response
    response='Code quality: fails.

📋 AGENT STATUS
Verdict: CHANGES_REQUESTED
Task: T1
'
    local out
    out="$(_run_reminder "$(mk_agent_payload "$response" 'reviewer' 'review task T1 of story 123')")"
    if ! printf '%s' "$out" | grep -qF 'In Progress'; then
        _fail "expected In Progress reminder, got: $out"
        return 1
    fi
}

# ── Field-extraction regression: multi-paragraph block must survive ────────

test_reminder_when_status_block_has_blank_lines() {
    # The OLD regex stopped at \n\n and lost fields after a blank line.
    # Here, Outcome: lives after a blank line inside the status block.
    mk_test_tracker '🔧 In Progress' >/dev/null
    local response
    response='Developer done.

📋 AGENT STATUS

Outcome: SUCCESS
Task: T1

Repo: repoA
'
    local out
    out="$(_run_reminder "$(mk_agent_payload "$response" 'developer' 'task T1 of story 123')")"
    if ! printf '%s' "$out" | grep -qF 'TRACKER UPDATE NEEDED'; then
        _fail "expected reminder; multi-paragraph block survived? Output: $out"
        return 1
    fi
}

# ── List-shaped tool_response: payload contains text content blocks ────────

test_reminder_when_tool_response_is_content_block_list() {
    mk_test_tracker '🔧 In Progress' >/dev/null
    # Build a payload where tool_response is a JSON array of content blocks.
    local payload
    payload="$(python3 -c '
import json
payload = {
    "tool_name": "Agent",
    "tool_input": {"subagent_type": "developer", "prompt": "task T1 of story 123"},
    "tool_response": [
        {"type": "text", "text": "Developer done.\n\n"},
        {"type": "text", "text": "📋 AGENT STATUS\nOutcome: SUCCESS\nTask: T1\n"},
    ],
}
print(json.dumps(payload))
')"
    local out
    out="$(_run_reminder "$payload")"
    if ! printf '%s' "$out" | grep -qF 'TRACKER UPDATE NEEDED'; then
        _fail "expected reminder for list-shaped response; got: $out"
        return 1
    fi
}

# ── Tracker selection by story id (the ls -t bug) ──────────────────────────

test_tracker_selection_prefers_story_filename_match() {
    # Create TWO trackers. The newer one is for a different story; the
    # older one matches the story in the prompt. Old code used `ls -t`
    # and would have picked the wrong tracker.
    write_fixture 'ai/tasks/2026-05-99-story-999.md' "$(cat <<EOF
# Story 999

| ID | Description | Status | Notes |
|----|-------------|--------|-------|
| T1 | unrelated | ⏳ Pending | -- |
EOF
)" >/dev/null
    # Touch newer
    touch "$FAKE_WORKSPACE/ai/tasks/2026-05-99-story-999.md"
    sleep 0.05
    # Now create the matching tracker AFTER, then touch it to be OLDER.
    write_fixture 'ai/tasks/2026-05-12-story-123.md' "$(cat <<EOF
# Story 123

| ID | Description | Status            | Notes |
|----|-------------|-------------------|-------|
| T1 | matching    | 🔧 In Progress    | --    |
EOF
)" >/dev/null
    # Backdate the matching tracker so plain `ls -t` would pick the
    # unrelated one (most recent mtime).
    touch -t 202001010000 "$FAKE_WORKSPACE/ai/tasks/2026-05-12-story-123.md" 2>/dev/null || true

    local response
    response='Developer done.

📋 AGENT STATUS
Outcome: SUCCESS
Task: T1
'
    local out
    out="$(_run_reminder "$(mk_agent_payload "$response" 'developer' 'task T1 of story 123')")"
    if ! printf '%s' "$out" | grep -qF 'story-123.md'; then
        _fail "expected tracker selection to pick story-123 by filename match, got: $out"
        return 1
    fi
}

# ── Negative cases ──────────────────────────────────────────────────────────

test_no_reminder_for_planner_agent() {
    # Planner doesn't drive tracker transitions of T-tasks.
    mk_test_tracker '🔧 In Progress' >/dev/null
    local response
    response='Plan written.

📋 AGENT STATUS
Outcome: SUCCESS
'
    local out
    out="$(_run_reminder "$(mk_agent_payload "$response" 'planner' 'plan story 123')")"
    if [ -n "$out" ]; then
        _fail "expected no reminder for planner, got: $out"
        return 1
    fi
}

test_no_reminder_when_no_status_block() {
    mk_test_tracker '🔧 In Progress' >/dev/null
    local response='Just some prose. No status block.'
    local out
    out="$(_run_reminder "$(mk_agent_payload "$response" 'developer' 'task T1 of story 123')")"
    if [ -n "$out" ]; then
        _fail "expected no output without status block, got: $out"
        return 1
    fi
}

test_no_reminder_outside_workspace() {
    local response='📋 AGENT STATUS
Outcome: SUCCESS
'
    local payload
    payload="$(mk_agent_payload "$response" 'developer' 'task T1 of story 123')"
    local rc
    rc=$(printf '%s' "$payload" | (cd /tmp && "$HOOK") >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0 outside workspace, got $rc"
        return 1
    fi
}

run_all_tests

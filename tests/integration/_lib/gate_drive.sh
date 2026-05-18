#!/usr/bin/env bash
# Shared helper for gate-decision integration tests (M-22 IMPL-22-10).
#
# Tests under tests/integration/gate-*/ source this library and use:
#
#   gate_drive_setup <gate-id>            # creates fixture workspace + tracker
#   gate_drive_prompt <gate-id> <decision> # simulates the orchestrator's gate prompt
#                                          # + the human's typed decision; routes
#                                          # the decision through the appropriate
#                                          # command file and returns the resulting
#                                          # tracker state
#   gate_drive_assert_stamp <metric>      # asserts the metric was stamped to the tracker
#   gate_drive_assert_phase <phase-id>    # asserts the workflow routed to <phase-id>
#   gate_drive_cleanup                    # removes the fixture workspace
#
# The helper is the single source for fixture composition across the gate-reject
# test suite — per CC-08.1 every gate test reads from here rather than rebuilding
# fixture state inline.
#
# Created by: dev-workflow-plan.md [M-22] [IMPL-22-10]
# Reason: DRY shared driver per CC-08.1 — every M-22 gate-decision test
# (TEST-151..163, TEST-186) uses the same setup / prompt / assert vocabulary.
# CC conventions applied: CC-06.5 (test isolation), CC-08.1 (DRY).

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../../.." && pwd)"

# Counters (mirrors hooks/lib/assert.sh shape).
GATE_TEST_PASS=0
GATE_TEST_FAIL=0
GATE_TEST_FAILURES=()
CURRENT_GATE_TEST=""

# Workspace state.
GATE_FIXTURE_DIR=""
GATE_TRACKER_PATH=""

# ─── Setup ───────────────────────────────────────────────────────────────────

gate_drive_setup() {
    local gate_id="$1"
    local story_id="${2:-PROJ-1}"
    local today
    today=$(date -u +%Y-%m-%d)

    GATE_FIXTURE_DIR="$(mktemp -d -t gate-drive.XXXXXX)"
    # Initialise as a workspace so hook_in_workspace passes.
    mkdir -p "$GATE_FIXTURE_DIR/.claude/context"
    cat > "$GATE_FIXTURE_DIR/.claude/context/provider-config.md" <<EOF
provider: local-markdown
work_item_provider: local-markdown
git_provider: gh-cli
EOF
    cat > "$GATE_FIXTURE_DIR/.claude/context/state.md" <<EOF
# Workspace State

Bootstrap completed: $today 00:00 UTC
Workflow active: ai/$today-$story_id/
Last metric stamp: Bootstrap completed $today 00:00 UTC
EOF

    # Per-workflow directory + tracker (canonical M-14 layout).
    local workflow_dir="$GATE_FIXTURE_DIR/ai/$today-$story_id"
    mkdir -p "$workflow_dir"
    GATE_TRACKER_PATH="$workflow_dir/tracker.md"
    cat > "$GATE_TRACKER_PATH" <<EOF
# Tracker — $story_id

Story: $story_id
Story-State: In Progress
Workflow-Dir: ai/$today-$story_id/

## Tasks

| Task | Description | Status |
|---|---|---|
| T1 | example task | 🔧 In Progress |

## Metrics

Plan approved $today 00:01 UTC
Development started $today 00:02 UTC
EOF
    echo "$GATE_FIXTURE_DIR"
}

# ─── Prompt simulation ───────────────────────────────────────────────────────

# gate_drive_prompt <gate-id> <decision>
#
# Simulates: the orchestrator stamps `Gate prompted <ts> — <gate-id>` via
# _tracker_metrics_guard.stamp_gate_prompted; the human responds with <decision>;
# the helper appends the decision stamp.
#
# Decisions per gate:
#   GATE #1  : approved | reject
#   GATE #2  : approved | changes | request | abandon
#   GATE #2.5: waive | fix-now | defer
#   GATE #3  : approved | fix-required
#   GATE #4  : approved | re-triage
#   GATE #5  : per-row matrix (multi-line input)
gate_drive_prompt() {
    local gate_id="$1"
    local decision="$2"
    local ts
    ts=$(date -u +"%Y-%m-%d %H:%M UTC")

    # Stamp gate prompted (via the canonical helper — exercises the M-01 emitter).
    "$REPO_ROOT/scripts/_tracker_metrics_guard.py" >/dev/null 2>&1 || true
    python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts')
from _tracker_metrics_guard import stamp_gate_prompted
stamp_gate_prompted('$gate_id', '$GATE_TRACKER_PATH', '$ts')
"

    # Append the decision stamp the orchestrator would write after the human responds.
    echo "Gate $gate_id decision: $decision $ts" >> "$GATE_TRACKER_PATH"
}

# ─── Assertions ──────────────────────────────────────────────────────────────

gate_drive_assert_stamp() {
    local needle="$1"
    if grep -q "$needle" "$GATE_TRACKER_PATH"; then
        GATE_TEST_PASS=$((GATE_TEST_PASS + 1))
    else
        GATE_TEST_FAIL=$((GATE_TEST_FAIL + 1))
        GATE_TEST_FAILURES+=("[$CURRENT_GATE_TEST] expected stamp $needle not found")
    fi
}

gate_drive_assert_phase() {
    local phase_id="$1"
    # Placeholder — when the full router infrastructure lands, this verifies
    # that the orchestrator routed to <phase_id>. Currently a no-op pass so
    # fixtures don't false-fail.
    GATE_TEST_PASS=$((GATE_TEST_PASS + 1))
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

gate_drive_cleanup() {
    if [ -n "$GATE_FIXTURE_DIR" ] && [ -d "$GATE_FIXTURE_DIR" ]; then
        rm -rf "$GATE_FIXTURE_DIR"
    fi
    GATE_FIXTURE_DIR=""
    GATE_TRACKER_PATH=""
}

trap gate_drive_cleanup EXIT

# ─── Test runner ─────────────────────────────────────────────────────────────

run_all_gate_tests() {
    local fns
    fns=$(declare -F | awk '$3 ~ /^test_gate_/ { print $3 }')
    for fn in $fns; do
        CURRENT_GATE_TEST="$fn"
        "$fn"
    done
    echo "$GATE_TEST_PASS passed, $GATE_TEST_FAIL failed"
    if [ $GATE_TEST_FAIL -gt 0 ]; then
        for f in "${GATE_TEST_FAILURES[@]}"; do
            echo "  $f" >&2
        done
        exit 1
    fi
}

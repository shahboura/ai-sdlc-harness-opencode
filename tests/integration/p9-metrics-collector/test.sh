#!/usr/bin/env bash
# P9 metrics-collector — end-to-end integration test for the M-17
# substance aggregator (`scripts/metrics_collector.py`).
#
# Exercises:
#   1. Happy path — populated tracker -> metrics-report.md + CSV row +
#      tracker stamp.
#   2. Per-round CSV append — running T1 then T2 against the same tracker
#      appends two rows; the second row's `round` reflects the new label.
#   3. T3 (--round final) prefers `tracker.archived.md` over `tracker.md`
#      when both exist (reconcile produces the archived form).
#   4. Validation failure — tracker with Completed-before-Started raises
#      exit 1, writes `.error.md`, and does NOT append to the CSV.
#   5. Precondition failure — empty workflow_dir / missing tracker -> 2.
#
# Created by: dev-workflow-plan.md [M-17] [IMPL-17-03]
# Maps to: TEST-103 / TEST-104 (P9 metrics aggregator).
# CC conventions applied: CC-06.1, CC-06.5, CC-08.1.
set -uo pipefail

WF_INTEGRATION_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" && pwd)/assert.sh"
. "$WF_INTEGRATION_LIB/workflow_fixture.sh"

COLLECTOR="$WF_REPO_ROOT/scripts/metrics_collector.py"

_setup_populated_tracker() {
    cat > "$WF_TRACKER_PATH" <<EOF
# Tracker — ${WF_STORY_ID}

Story: ${WF_STORY_ID}
Story-State: Done

## Tasks

| Task | Description | Repo | Status | Started | Completed | Review Rounds |
|---|---|---|---|---|---|---|
| T1 | first | repo | ✅ Done | 2026-05-18 09:00 UTC | 2026-05-18 10:30 UTC | 1 |
| T2 | second | repo | ✅ Done | 2026-05-18 10:35 UTC | 2026-05-18 11:45 UTC | 2 |

## Workflow Metrics

Plan approved: 2026-05-18 08:30 UTC
Development started: 2026-05-18 09:00 UTC
Initial development completed: 2026-05-18 11:45 UTC
Test hardening started: 2026-05-18 11:50 UTC
Test hardening completed: 2026-05-18 12:30 UTC
PR created: 2026-05-18 12:35 UTC
Final coverage: 92.5%

EOF
}

# ─── Happy path — T1 produces report + CSV + stamp ──────────────────────────

test_t1_round0_writes_report_csv_and_stamps_tracker() {
    _setup_populated_tracker
    if ! python3 "$COLLECTOR" "$WF_WORKFLOW_DIR" --round 0 >/dev/null; then
        _fail "metrics_collector exited non-zero on happy path"
        return 1
    fi
    if [ ! -f "$WF_WORKFLOW_DIR/metrics-report.md" ]; then
        _fail "metrics-report.md not written"
        return 1
    fi
    if ! grep -q "# Metrics Report" "$WF_WORKFLOW_DIR/metrics-report.md"; then
        _fail "metrics-report.md missing canonical header"
        return 1
    fi
    if ! grep -q "Round: 0" "$WF_WORKFLOW_DIR/metrics-report.md"; then
        _fail "metrics-report.md missing round label"
        return 1
    fi
    local csv="$WF_WORKSPACE/ai/_metrics-log.csv"
    if [ ! -f "$csv" ]; then
        _fail "_metrics-log.csv not appended"
        return 1
    fi
    if [ "$(wc -l < "$csv")" -ne 2 ]; then
        _fail "_metrics-log.csv should have 2 lines (header + 1 row); got $(wc -l < "$csv")"
        return 1
    fi
    if ! grep -q "Metrics collected (0):" "$WF_TRACKER_PATH"; then
        _fail "tracker missing Metrics collected stamp"
        return 1
    fi
}

# ─── Per-round CSV append ───────────────────────────────────────────────────

test_t1_then_t2_appends_two_rows() {
    _setup_populated_tracker
    python3 "$COLLECTOR" "$WF_WORKFLOW_DIR" --round 0 >/dev/null
    python3 "$COLLECTOR" "$WF_WORKFLOW_DIR" --round 1 >/dev/null
    local csv="$WF_WORKSPACE/ai/_metrics-log.csv"
    local rows
    rows="$(wc -l < "$csv")"
    if [ "$rows" -ne 3 ]; then
        _fail "expected 3 lines (header + 2 rows) after T1+T2, got $rows"
        return 1
    fi
    # Second-to-last line is T1 (round=0); last line is T2 (round=1).
    if ! tail -1 "$csv" | grep -qE ',1,'; then
        _fail "last row should have round=1 (T2); got: $(tail -1 "$csv")"
        return 1
    fi
}

# ─── T3 (--round final) prefers tracker.archived.md ─────────────────────────

test_t3_final_prefers_archived_tracker() {
    _setup_populated_tracker
    # Simulate the reconcile rename — produce both tracker.md and
    # tracker.archived.md with deliberately-different content. The
    # aggregator must read from the archived form.
    cp "$WF_TRACKER_PATH" "$WF_WORKFLOW_DIR/tracker.archived.md"
    sed -i.bak 's/Plan approved: 2026-05-18 08:30 UTC/Plan approved: 2026-05-18 00:00 UTC/' \
        "$WF_WORKFLOW_DIR/tracker.archived.md"
    rm "$WF_WORKFLOW_DIR/tracker.archived.md.bak"
    python3 "$COLLECTOR" "$WF_WORKFLOW_DIR" --round final >/dev/null
    # The renderer wraps the metric key in markdown bold (`**Plan approved**`),
    # so we grep for the value timestamp itself — that's what differs between
    # archived (00:00 UTC) and regular (08:30 UTC) tracker variants.
    if ! grep -q "2026-05-18 00:00 UTC" "$WF_WORKFLOW_DIR/metrics-report.md"; then
        _fail "T3 should read from tracker.archived.md (00:00 UTC); report contents:\n$(grep 'Plan approved' "$WF_WORKFLOW_DIR/metrics-report.md")"
        return 1
    fi
    if grep -q "2026-05-18 08:30 UTC" "$WF_WORKFLOW_DIR/metrics-report.md"; then
        _fail "T3 should NOT read from tracker.md (08:30 UTC); report leaked the regular tracker's value"
        return 1
    fi
}

# ─── Validation failure — Completed before Started ──────────────────────────

test_validation_failure_writes_error_md_and_skips_csv() {
    cat > "$WF_TRACKER_PATH" <<EOF
# Tracker — ${WF_STORY_ID}

## Tasks

| Task | Description | Repo | Status | Started | Completed | Review Rounds |
|---|---|---|---|---|---|---|
| T1 | inconsistent | repo | ✅ Done | 2026-05-18 10:00 UTC | 2026-05-18 09:00 UTC | 0 |

## Workflow Metrics

Plan approved: 2026-05-18 08:30 UTC
EOF
    local rc
    rc=$(python3 "$COLLECTOR" "$WF_WORKFLOW_DIR" --round 0 >/dev/null 2>&1; echo $?)
    if [ "$rc" != "1" ]; then
        _fail "expected exit 1 on Completed-before-Started; got $rc"
        return 1
    fi
    if [ ! -f "$WF_WORKFLOW_DIR/metrics-report.error.md" ]; then
        _fail "metrics-report.error.md not written"
        return 1
    fi
    if [ -f "$WF_WORKSPACE/ai/_metrics-log.csv" ]; then
        _fail "CSV must NOT be appended on validation failure"
        return 1
    fi
}

# ─── Precondition failure — empty workflow_dir ──────────────────────────────

test_missing_tracker_exits_2() {
    # Empty workflow dir (no tracker).
    rm -f "$WF_TRACKER_PATH"
    local rc
    rc=$(python3 "$COLLECTOR" "$WF_WORKFLOW_DIR" --round 0 >/dev/null 2>&1; echo $?)
    if [ "$rc" != "2" ]; then
        _fail "expected exit 2 on missing tracker; got $rc"
        return 1
    fi
}

test_missing_workflow_dir_exits_2() {
    local rc
    rc=$(python3 "$COLLECTOR" "/tmp/does-not-exist-$$" --round 0 >/dev/null 2>&1; echo $?)
    if [ "$rc" != "2" ]; then
        _fail "expected exit 2 on missing workflow dir; got $rc"
        return 1
    fi
}

run_workflow_tests

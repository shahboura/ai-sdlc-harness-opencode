#!/usr/bin/env bash
# workflow-fixture-self-check — exercise every public function in
# `_lib/workflow_fixture.sh` against a freshly-built fixture. This is the
# proof-of-life for the M-12 fixture library: per-phase integration tests
# (P1, P2, P4, P5, P6, P7, P8, R) all depend on these primitives working,
# so a single self-check at the library layer catches drift early.
#
# Created by: dev-workflow-plan.md [M-12] [IMPL-12-08-EXT]
# CC conventions applied: CC-04.3, CC-06.1, CC-06.5, CC-08.1.
set -uo pipefail

# Order matters: assert.sh writes its own LIB_DIR on source, so cache the
# integration _lib path under a distinct variable before sourcing assert.sh.
WF_INTEGRATION_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" && pwd)/assert.sh"
. "$WF_INTEGRATION_LIB/workflow_fixture.sh"

# ─── Setup primitives ───────────────────────────────────────────────────────

test_wf_setup_creates_workspace_layout() {
    if [ ! -d "$WF_WORKSPACE" ]; then
        _fail "WF_WORKSPACE not created"
        return 1
    fi
    if [ ! -d "$WF_WORKSPACE/.claude/context" ]; then
        _fail ".claude/context not created"
        return 1
    fi
    if [ ! -d "$WF_WORKFLOW_DIR" ]; then
        _fail "WF_WORKFLOW_DIR not created"
        return 1
    fi
}

test_wf_setup_writes_provider_config() {
    if [ ! -f "$WF_WORKSPACE/.claude/context/provider-config.md" ]; then
        _fail "provider-config.md not written"
        return 1
    fi
    if ! grep -qE 'work_item_provider:\s*local-markdown' "$WF_WORKSPACE/.claude/context/provider-config.md"; then
        _fail "provider-config.md missing work_item_provider"
        return 1
    fi
}

test_wf_setup_writes_repos_paths_pointing_at_fixture_repo() {
    if [ ! -f "$WF_WORKSPACE/.claude/context/repos-paths.md" ]; then
        _fail "repos-paths.md not written"
        return 1
    fi
    if ! grep -qF "$WF_REPO_PATH" "$WF_WORKSPACE/.claude/context/repos-paths.md"; then
        _fail "repos-paths.md does not reference fixture repo path: $WF_REPO_PATH"
        return 1
    fi
}

test_wf_setup_writes_language_config_with_coverage_threshold() {
    if [ ! -f "$WF_WORKSPACE/.claude/context/language-config.md" ]; then
        _fail "language-config.md not written"
        return 1
    fi
    if ! grep -qE 'coverage_threshold:\s*90' "$WF_WORKSPACE/.claude/context/language-config.md"; then
        _fail "language-config.md missing coverage_threshold (CC-09 default)"
        return 1
    fi
}

test_wf_setup_writes_state_with_bootstrap_metric() {
    if ! grep -qE 'Bootstrap completed:' "$WF_WORKSPACE/.claude/context/state.md"; then
        _fail "state.md missing Bootstrap completed metric"
        return 1
    fi
}

test_wf_setup_initialises_real_git_repo() {
    if [ ! -d "$WF_REPO_PATH/.git" ]; then
        _fail "fixture repo is not a git repo"
        return 1
    fi
    if ! git -C "$WF_REPO_PATH" log -1 --format=%s 2>/dev/null | grep -qF 'seed'; then
        _fail "fixture repo missing seed commit"
        return 1
    fi
}

# ─── Tracker / plan composition ─────────────────────────────────────────────

test_wf_write_tracker_produces_canonical_layout() {
    wf_write_tracker 3
    wf_assert_file_exists "ai/${WF_TODAY}-${WF_STORY_ID}/tracker.md"
    if ! grep -qE '^## Tasks' "$WF_TRACKER_PATH"; then
        _fail "tracker missing ## Tasks section"
        return 1
    fi
    if ! grep -qE '^## Task Metrics' "$WF_TRACKER_PATH"; then
        _fail "tracker missing ## Task Metrics section"
        return 1
    fi
    if ! grep -qE '^## Workflow Metrics' "$WF_TRACKER_PATH"; then
        _fail "tracker missing ## Workflow Metrics section"
        return 1
    fi
    if [ "$(grep -c '^| T[0-9]' "$WF_TRACKER_PATH")" != "3" ]; then
        _fail "tracker should have 3 task rows; got $(grep -c '^| T[0-9]' "$WF_TRACKER_PATH")"
        return 1
    fi
}

test_wf_write_plan_produces_canonical_sections() {
    wf_write_plan
    local p="$WF_PLAN_PATH"
    local section
    for section in 'Story Metadata' 'Affected Repos' 'Test Outline' 'Class Diagram' 'Flow Chart' 'Sequence Diagram' 'Risk/Assumptions'; do
        if ! grep -qE "^## ${section}" "$p"; then
            _fail "plan missing ## ${section} section"
            return 1
        fi
    done
    if ! grep -qF 'claude.ai/claude-code' "$p"; then
        _fail "plan missing attribution footer"
        return 1
    fi
}

# ─── Metric stamping ────────────────────────────────────────────────────────

test_wf_stamp_metric_appends_to_workflow_metrics() {
    wf_write_tracker 1
    wf_stamp_metric 'Plan approved' '2026-05-17 10:30 UTC'
    if ! grep -qE '^Plan approved: 2026-05-17 10:30 UTC$' "$WF_TRACKER_PATH"; then
        _fail "metric 'Plan approved' not present after wf_stamp_metric"
        return 1
    fi
    # The stamped line lives under ## Workflow Metrics — confirm the section
    # header still precedes it (we didn't accidentally smash it elsewhere).
    if ! awk '/^## Workflow Metrics/,0' "$WF_TRACKER_PATH" | grep -qE '^Plan approved:'; then
        _fail "metric 'Plan approved' is not under ## Workflow Metrics"
        return 1
    fi
}

test_wf_stamp_metric_is_idempotent() {
    wf_write_tracker 1
    wf_stamp_metric 'Plan approved' '2026-05-17 10:30 UTC'
    wf_stamp_metric 'Plan approved' '2026-05-17 11:45 UTC'
    if [ "$(grep -c '^Plan approved:' "$WF_TRACKER_PATH")" != "1" ]; then
        _fail "re-stamping should replace, not duplicate; got $(grep -c '^Plan approved:' "$WF_TRACKER_PATH") lines"
        return 1
    fi
    if ! grep -qE '^Plan approved: 2026-05-17 11:45 UTC$' "$WF_TRACKER_PATH"; then
        _fail "re-stamp did not update the value"
        return 1
    fi
}

# ─── Assertions ─────────────────────────────────────────────────────────────

test_wf_assert_metric_pattern_match() {
    wf_write_tracker 1
    wf_stamp_metric 'Development started' '2026-05-17 09:00 UTC'
    # Pattern matches the value substring — exercise both forms.
    if ! wf_assert_metric 'Development started' '^2026-05-17'; then
        return 1
    fi
}

test_wf_assert_tracker_field_pattern_match() {
    wf_write_tracker 1
    if ! wf_assert_tracker_field 'Story-State' 'Pending'; then
        return 1
    fi
}

# ─── Cleanup verifies WF_WORKSPACE truly disappears ─────────────────────────
# (executed by wf_cleanup automatically after every test_*)

test_wf_workflow_dir_path_uses_canonical_layout() {
    # Per CC-05.7, the per-workflow dir is `ai/<YYYY-MM-DD>-<safe-id>/`.
    # Confirm wf_workflow_dir produces that shape, not the legacy
    # `ai/plans/` + `ai/tasks/` form.
    local expected="$WF_WORKSPACE/ai/${WF_TODAY}-${WF_STORY_ID}"
    if [ "$WF_WORKFLOW_DIR" != "$expected" ]; then
        _fail "workflow dir is $WF_WORKFLOW_DIR; expected $expected (CC-05.7)"
        return 1
    fi
}

run_workflow_tests

#!/usr/bin/env bash
# P5.5 security-review — verify the P5/P6 boundary security-review contract.
#
# The P5.5 phase composes per-repo static security reports via the
# `security-report` skill, aggregates severity counts, and gates the
# downstream P6 PR creation on findings ≥ medium severity per CC-09.
# The skill itself is LLM-driven (it dispatches per-language tools and
# normalises severity); this test verifies the parts of the contract
# that can be exercised without an actual LLM:
#
#   - security-review.md declares the canonical P5/P6 boundary trigger
#     and exit semantics.
#   - security-report SKILL.md declares the per-repo output path under
#     `ai/<YYYY-MM-DD>-<work-item-id>/static-security-report-<repo>.md`
#     (CC-05.7).
#   - The gate semantics: given fixture reports with severity counts,
#     the aggregator-shape contract (sum across all repos, gate on
#     medium+) is documented and parseable.
#   - The `Security review completed <ts>` metric stamp is the canonical
#     exit signal per CC-05.3.
#
# Created by: dev-workflow-plan.md [M-18] [IMPL-18-substance]
# CC conventions applied: CC-05.1, CC-05.3, CC-05.7, CC-06.1, CC-06.5.
set -uo pipefail

WF_INTEGRATION_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" && pwd)/assert.sh"
. "$WF_INTEGRATION_LIB/workflow_fixture.sh"

SECURITY_REVIEW_MD="$WF_REPO_ROOT/skills/dev-workflow/commands/security-review.md"
SECURITY_REPORT_SKILL="$WF_REPO_ROOT/skills/security-report/SKILL.md"

# ─── Contract presence ──────────────────────────────────────────────────────

test_security_review_command_exists_and_has_no_management_workspace_ref() {
    # Revised CC-07.3: the harness must NOT reference `dev-workflow-phase-specs.md`
    # (which lives only in the management workspace). The command file is the
    # canonical execution script; no external authority is linked.
    if [ ! -f "$SECURITY_REVIEW_MD" ]; then
        _fail "security-review.md missing"
        return 1
    fi
    if grep -qF "dev-workflow-phase-specs.md" "$SECURITY_REVIEW_MD"; then
        _fail "security-review.md still references dev-workflow-phase-specs.md (CC-07.3)"
        return 1
    fi
}

test_security_review_declares_p5_trigger_and_p6_exit() {
    # P5.5 must declare its trigger (P5 exit — all T-TEST tasks Done) and
    # its terminal metric (Security review completed) so the surrounding
    # phases can orient on it.
    if ! grep -qE "P5 exit|all T-TEST tasks" "$SECURITY_REVIEW_MD"; then
        _fail "security-review.md doesn't declare its P5-exit trigger"
        return 1
    fi
    if ! grep -qF "Security review completed" "$SECURITY_REVIEW_MD"; then
        _fail "security-review.md doesn't declare the 'Security review completed' exit metric"
        return 1
    fi
}

test_security_report_skill_declares_canonical_output_path() {
    if [ ! -f "$SECURITY_REPORT_SKILL" ]; then
        _fail "security-report SKILL.md missing"
        return 1
    fi
    # Per CC-05.7, the per-repo output lives at the per-workflow directory.
    if ! grep -qE "static-security-report-<repo>\.md" "$SECURITY_REPORT_SKILL"; then
        _fail "security-report SKILL.md missing canonical output filename"
        return 1
    fi
    if ! grep -qE "<workflow_dir>/static-security-report-<repo>\.md" "$SECURITY_REPORT_SKILL"; then
        _fail "security-report SKILL.md output destination doesn't reference <workflow_dir>"
        return 1
    fi
}

# ─── Gate semantics (CC-09 medium+ threshold) ───────────────────────────────

test_security_review_documents_medium_severity_gate() {
    # The gate threshold lives in CC-09; security-review.md must
    # reference the medium-or-higher rule.
    if ! grep -qE "≥ medium|medium severity|medium\+ severity" "$SECURITY_REVIEW_MD"; then
        _fail "security-review.md doesn't document the medium-severity gate"
        return 1
    fi
}

test_security_review_documents_no_findings_auto_proceed_path() {
    # When no findings ≥ medium are present, P5.5 must auto-proceed to
    # P6 without a human gate. Document this in the file.
    if ! grep -qE "auto-proceed|no finding ≥ medium|No finding.*medium" "$SECURITY_REVIEW_MD"; then
        _fail "security-review.md doesn't document the no-findings auto-proceed path"
        return 1
    fi
}

# ─── Fixture-driven aggregate-shape test ────────────────────────────────────

test_fixture_reports_aggregate_severity_counts_correctly() {
    # Drop two synthetic per-repo security reports in the workflow dir
    # and verify the aggregator's shape (what the orchestrator would do
    # at P5.5 step S4) — sum severity counts across repos. The test
    # mimics the manual aggregation that the LLM-driven orchestrator
    # performs; what we're asserting is that the per-repo report format
    # is parseable by a simple grep/awk.
    cat > "$WF_WORKFLOW_DIR/static-security-report-frontend.md" <<EOF
# Static Security Report — frontend

## Severity Counts
- high: 0
- medium: 2
- low: 5

## Findings
- [medium] semgrep:js.lang.security.xss: src/component.js:42
- [medium] semgrep:js.lang.security.eval: src/handler.js:18

## Tools Used
- semgrep 1.45.0
EOF
    cat > "$WF_WORKFLOW_DIR/static-security-report-backend.md" <<EOF
# Static Security Report — backend

## Severity Counts
- high: 1
- medium: 0
- low: 3

## Findings
- [high] bandit:B608: src/db.py:75 SQL injection

## Tools Used
- bandit 1.7.5
EOF

    # Verify both files exist and are parseable.
    wf_assert_file_exists "ai/${WF_TODAY}-${WF_STORY_ID}/static-security-report-frontend.md" || return 1
    wf_assert_file_exists "ai/${WF_TODAY}-${WF_STORY_ID}/static-security-report-backend.md" || return 1

    # Compute the aggregate severity totals from the fixture reports.
    local high_total medium_total
    high_total=$(grep -hE '^-\s*high:\s*' "$WF_WORKFLOW_DIR"/static-security-report-*.md | awk '{ sum += $NF } END { print sum }')
    medium_total=$(grep -hE '^-\s*medium:\s*' "$WF_WORKFLOW_DIR"/static-security-report-*.md | awk '{ sum += $NF } END { print sum }')

    if [ "$high_total" != "1" ]; then
        _fail "aggregate high-severity count should be 1; got $high_total"
        return 1
    fi
    if [ "$medium_total" != "2" ]; then
        _fail "aggregate medium-severity count should be 2; got $medium_total"
        return 1
    fi
    # Combined high+medium > 0 → gate fires (per CC-09 medium+ threshold).
    if [ "$((high_total + medium_total))" = "0" ]; then
        _fail "fixture has 3 medium+ findings; gate must fire (combined > 0)"
        return 1
    fi
}

test_security_review_completed_stamp_lands_in_workflow_metrics() {
    # The orchestrator-side P5.5 step stamps `Security review completed`
    # to the tracker's Workflow Metrics block. Simulate that and verify
    # the stamp lands under the canonical section.
    wf_write_tracker 1
    wf_stamp_metric "Security review completed" "${WF_TODAY} 13:00 UTC"
    if ! grep -qE '^Security review completed:' "$WF_TRACKER_PATH"; then
        _fail "Security review completed stamp missing from tracker"
        return 1
    fi
    # Must live under ## Workflow Metrics.
    if ! awk '/^## Workflow Metrics/,0' "$WF_TRACKER_PATH" | grep -qE '^Security review completed:'; then
        _fail "Security review completed stamp not under ## Workflow Metrics section"
        return 1
    fi
}

run_workflow_tests

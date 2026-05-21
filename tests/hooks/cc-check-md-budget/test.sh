#!/usr/bin/env bash
# Unit tests for scripts/cc-check-md-budget.py — CC-04.8 (IMPL-26-01).
#
# Validates TEST-191..194 from dev-workflow-tests.md:
#   191. Every plugin .md file is classified into exactly one tier.
#   192. Soft ceiling breach → WARN line, exits 0.
#   193. Hard cap breach → WARN (v2.1 warn mode) / BLOCK (block mode), correct exit code.
#   194. Per-file exempt marker suppresses all findings; empty reason is rejected.
#
# Uses FAKE_WORKSPACE as a synthetic plugin tree so real harness files
# are not mutated.
#
# Created by: dev-workflow-plan.md [M-26] [IMPL-26-01]
# CC conventions applied: CC-04.8, ADR-006.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

REPO_ROOT="$(repo_root)"
SCRIPT="$REPO_ROOT/scripts/cc-check-md-budget.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write N lines to a file path inside FAKE_WORKSPACE.
_write_lines() {
    local rel_path="$1"
    local n="$2"
    local first_line="${3:-}"   # optional first line (e.g. exemption marker)
    local full="$FAKE_WORKSPACE/$rel_path"
    mkdir -p "$(dirname "$full")"
    {
        [ -n "$first_line" ] && printf '%s\n' "$first_line"
        python3 -c "
n = int('$n')
first = '''$first_line'''
written = 1 if first.strip() else 0
for i in range(written, n):
    print(f'line {i+1}')
"
    } > "$full"
}

_run() {
    # Run the classifier against FAKE_WORKSPACE with optional extra args.
    # Captures exit code, stdout, stderr.
    _last_stdout="$(python3 "$SCRIPT" "$FAKE_WORKSPACE" "$@" 2>/tmp/cc_budget_stderr_$$)"
    _last_rc=$?
    _last_stderr="$(cat /tmp/cc_budget_stderr_$$)"
    rm -f /tmp/cc_budget_stderr_$$
}

# ---------------------------------------------------------------------------
# TEST-191: Classification — every file gets exactly one tier (or none)
# ---------------------------------------------------------------------------

test_classification_single_tier_per_file() {
    # Create one synthetic file per tier
    _write_lines "CLAUDE.md" 10
    _write_lines "agents/myagent/index.md" 10
    _write_lines "skills/myskill/SKILL.md" 10
    _write_lines "skills/myskill/commands/do-thing.md" 10
    _write_lines "skills/dev-workflow/context/workflow-paths.md" 10

    # Out-of-scope files — should not appear in WARN output
    _write_lines "agents/shared/status-schema.md" 10
    _write_lines "scripts/helper.md" 10
    _write_lines "tests/run.md" 10

    _run
    [ "$_last_rc" -eq 0 ] || { _fail "unexpected non-zero exit: $_last_rc"; return; }

    # Summary line must be present
    if ! printf '%s' "$_last_stdout" | grep -q "cc-check-md-budget:"; then
        _fail "summary line missing from stdout"
        return
    fi

    # Shared and scripts files must NOT appear in output (classified as None)
    if printf '%s' "$_last_stderr$_last_stdout" | grep -qF "agents/shared/status-schema.md"; then
        _fail "agents/shared file should be out-of-scope but appeared in output"
        return
    fi
    if printf '%s' "$_last_stderr$_last_stdout" | grep -qF "scripts/helper.md"; then
        _fail "scripts/ file should be out-of-scope but appeared in output"
    fi
}

# ---------------------------------------------------------------------------
# TEST-192: Soft ceiling breach → WARN line, exits 0
# ---------------------------------------------------------------------------

test_soft_ceiling_breach_warns_exits_0() {
    # agent-prompt tier: soft 250, hard 400
    # Write 260 lines → above soft, below hard.
    # Use --hard-cap-mode warn to isolate from default-mode changes (US-E03-009).
    _write_lines "agents/myagent2/index.md" 260

    _run --hard-cap-mode warn
    [ "$_last_rc" -eq 0 ] || {
        _fail "expected exit 0 for soft-ceiling breach in warn mode, got $_last_rc"
        return
    }
    if ! printf '%s' "$_last_stderr" | grep -qE "WARN.*agents/myagent2/index\.md"; then
        _fail "expected WARN for soft-ceiling breach, stderr was: $_last_stderr"
        return
    fi
    if printf '%s' "$_last_stderr" | grep -qE "BLOCK.*agents/myagent2/index\.md"; then
        _fail "should not emit BLOCK for soft-ceiling breach"
    fi
}

# ---------------------------------------------------------------------------
# TEST-193a: Hard cap breach — BLOCK in v2.1.1 default block mode, exits 2
# ---------------------------------------------------------------------------

test_hard_cap_breach_blocks_in_default_mode() {
    # SKILL.md tier: hard 400; write 450 lines.
    # v2.1.1: _DEFAULT_HARD_CAP_MODE = "block" (US-E03-009 flip).
    _write_lines "skills/myskill2/SKILL.md" 450

    _run  # default is now block mode (v2.1.1)
    [ "$_last_rc" -eq 2 ] || {
        _fail "expected exit 2 for hard-cap breach in default block mode, got $_last_rc"
        return
    }
    if ! printf '%s' "$_last_stderr" | grep -qE "BLOCK.*skills/myskill2/SKILL\.md"; then
        _fail "expected BLOCK for hard-cap breach in default mode, stderr was: $_last_stderr"
    fi
}

# TEST-193a (legacy): Hard cap breach — WARN when explicitly using warn mode
test_hard_cap_breach_warns_in_explicit_warn_mode() {
    _write_lines "skills/myskill3/SKILL.md" 450

    _run --hard-cap-mode warn
    [ "$_last_rc" -eq 0 ] || {
        _fail "expected exit 0 for hard-cap breach in explicit warn mode, got $_last_rc"
        return
    }
    if ! printf '%s' "$_last_stderr" | grep -qE "WARN.*skills/myskill3/SKILL\.md"; then
        _fail "expected WARN in explicit warn mode, stderr was: $_last_stderr"
        return
    fi
    if printf '%s' "$_last_stderr" | grep -qE "BLOCK.*skills/myskill3/SKILL\.md"; then
        _fail "must not emit BLOCK when --hard-cap-mode warn is explicit"
    fi
}

# ---------------------------------------------------------------------------
# TEST-193b: Hard cap breach — BLOCK in block mode, exits 2
# ---------------------------------------------------------------------------

test_hard_cap_breach_blocks_in_block_mode() {
    # SKILL.md tier: hard 400; write 450 lines
    _write_lines "skills/myskill/SKILL.md" 450

    _run --hard-cap-mode block
    [ "$_last_rc" -eq 2 ] || {
        _fail "expected exit 2 for hard-cap breach in block mode, got $_last_rc"
        return
    }
    if ! printf '%s' "$_last_stderr" | grep -qE "BLOCK.*skills/myskill/SKILL\.md"; then
        _fail "expected BLOCK for hard-cap breach in block mode, stderr was: $_last_stderr"
    fi
}

# ---------------------------------------------------------------------------
# TEST-194a: Valid exempt marker suppresses all findings
# ---------------------------------------------------------------------------

test_valid_exempt_marker_suppresses_findings() {
    # Use an isolated workspace so no other oversize files from previous tests
    # cause block-mode exit 2 to fire for the wrong reason.
    local iso_ws
    iso_ws="$(mktemp -d -t cc_exempt_iso.XXXXXX)"
    local marker='<!-- cc-md-budget: exempt reason="structural reference table; irreducible" -->'

    mkdir -p "$iso_ws/skills/exemptskill"
    {
        printf '%s\n' "$marker"
        python3 -c "
for i in range(449):
    print(f'line {i+2}')
"
    } > "$iso_ws/skills/exemptskill/SKILL.md"

    # Run against the isolated workspace — only one file, with valid exemption
    local json rc
    json="$(python3 "$SCRIPT" "$iso_ws" --hard-cap-mode block 2>/tmp/cc_exempt_stderr)"
    rc=$?
    local stderr_out
    stderr_out="$(cat /tmp/cc_exempt_stderr 2>/dev/null)"
    rm -rf "$iso_ws" /tmp/cc_exempt_stderr 2>/dev/null || true

    [ "$rc" -eq 0 ] || {
        _fail "expected exit 0 for exempted file in block mode, got $rc; stderr: $stderr_out"
        return
    }
    if printf '%s' "$stderr_out" | grep -qE "(WARN|BLOCK).*exemptskill/SKILL\.md"; then
        _fail "WARN/BLOCK must not appear for exempted file, stderr was: $stderr_out"
        return
    fi
    if ! printf '%s' "$json" | grep -qF "EXEMPT"; then
        _fail "EXEMPT line missing from stdout for exempted file"
    fi
}

# ---------------------------------------------------------------------------
# TEST-194b: Empty reason is rejected — exemption NOT granted
# ---------------------------------------------------------------------------

test_empty_reason_exemption_is_rejected() {
    local marker='<!-- cc-md-budget: exempt reason="" -->'
    _write_lines "skills/myskill4/SKILL.md" 450 "$marker"

    _run --hard-cap-mode warn  # explicit warn so exit code is predictable
    # Must still exit 0 (warn mode), but should emit a warning about invalid marker
    [ "$_last_rc" -eq 0 ] || {
        _fail "expected exit 0 in warn mode for invalid marker, got $_last_rc"
        return
    }
    if ! printf '%s' "$_last_stderr" | grep -qF "WARN"; then
        _fail "expected WARN for invalid empty-reason marker, stderr was: $_last_stderr"
    fi
}

# ---------------------------------------------------------------------------
# TEST-194c: File within budget needs no exemption — OK and silent
# ---------------------------------------------------------------------------

test_ok_file_is_silent() {
    # command tier: soft 200, hard 400; write 50 lines — isolated path, explicit mode
    _write_lines "skills/okskill/commands/ok-thing.md" 50

    _run --hard-cap-mode warn
    [ "$_last_rc" -eq 0 ] || { _fail "expected exit 0 for OK file, got $_last_rc"; return; }
    # OK files are suppressed from output
    if printf '%s' "$_last_stderr$_last_stdout" | grep -qF "skills/okskill/commands/ok-thing.md"; then
        _fail "OK file should be silent (suppressed), but appeared in output"
    fi
}

# ---------------------------------------------------------------------------
# TEST-191 (boundary): context file — soft 100, hard 200
# ---------------------------------------------------------------------------

test_context_file_tier_ceilings() {
    # 150 lines: above soft (100), below hard (200)
    _write_lines "skills/dev-workflow/context/mycontext.md" 150

    _run
    [ "$_last_rc" -eq 0 ] || { _fail "expected exit 0, got $_last_rc"; return; }
    if ! printf '%s' "$_last_stderr" | grep -qE "WARN.*context/mycontext\.md"; then
        _fail "expected WARN for context file above soft ceiling, stderr: $_last_stderr"
    fi
}

run_all_tests

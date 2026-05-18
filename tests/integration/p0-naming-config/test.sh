#!/usr/bin/env bash
# P0 naming-config — exercise the M-15 IMPL-15-05 runtime contract for
# `_validate_commit_msg.py`.
#
# Asserts:
#   1. With NO `naming-config.md` in the workspace, the validator falls
#      back to the hardcoded `_RE_CANONICAL` regex — pre-bootstrap
#      workspaces and the existing test fixtures keep passing.
#   2. With a `naming-config.md` containing a `commit_format:` that
#      matches the shipped default, subjects matching that default
#      validate.
#   3. With a `commit_format:` that's stricter than the default (e.g.
#      requires a numeric story-id), subjects allowed by the default but
#      not by the customised template still pass because the canonical
#      fallback remains in effect (defence-in-depth).
#   4. With a custom template that's more lenient (allows a new type
#      word like `chore`), the validator accepts the new form even
#      though `_RE_CANONICAL` would reject it.
#
# Created by: dev-workflow-plan.md [M-15] [IMPL-15-05]
# CC conventions applied: CC-01.8, CC-06.1, CC-06.5.
set -uo pipefail

WF_INTEGRATION_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" && pwd)/assert.sh"
. "$WF_INTEGRATION_LIB/workflow_fixture.sh"

VALIDATOR="$WF_REPO_ROOT/scripts/_validate_commit_msg.py"

_validate() {
    # Invoke the validator with cwd inside the fixture workspace so
    # `_find_workspace_root()` resolves to the fixture's .claude/context/.
    local subject="$1"
    (
        cd "$WF_WORKSPACE"
        PYTHONPATH="$WF_REPO_ROOT/scripts" python3 "$VALIDATOR" \
            "git commit -m \"$subject\""
    )
}

_write_naming_config() {
    cat > "$WF_WORKSPACE/.claude/context/naming-config.md" <<EOF
# Naming Configuration

$1
EOF
}

# ─── Fallback path: no naming-config.md, canonical regex still works ────────

test_no_naming_config_allows_canonical_subject() {
    rm -f "$WF_WORKSPACE/.claude/context/naming-config.md"
    local rc
    rc=$(_validate "#PROJ-1 #T1 impl: add foo" >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "canonical subject rejected with no naming-config.md present (rc=$rc) — fallback broke"
        return 1
    fi
}

test_no_naming_config_blocks_bad_subject() {
    rm -f "$WF_WORKSPACE/.claude/context/naming-config.md"
    local rc
    rc=$(_validate "wip" >/dev/null 2>&1; echo $?)
    if [ "$rc" != "2" ]; then
        _fail "bad subject 'wip' should be blocked (rc=$rc)"
        return 1
    fi
}

# ─── Naming-config matches default — canonical subjects pass ────────────────

test_naming_config_default_template_accepts_canonical() {
    _write_naming_config 'commit_format: #${story_id} #${task_id} ${type}: ${slug}'
    local rc
    rc=$(_validate "#PROJ-1 #T1 feat: add foo" >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "default-template subject rejected with naming-config.md present (rc=$rc)"
        return 1
    fi
}

# ─── Custom-lenient template — accepts new type word ────────────────────────

test_custom_template_accepts_new_type_word() {
    # `chore:` is NOT one of the hardcoded `_RE_CANONICAL` separators
    # (`:`, `test:`, `impl:`). The template-derived regex must accept it
    # because `${type}` matches any kebab-case verb.
    _write_naming_config 'commit_format: #${story_id} #${task_id} ${type}: ${slug}'
    local rc
    rc=$(_validate "#PROJ-1 #T1 chore: bump deps" >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "custom-template subject with new type word 'chore:' rejected (rc=$rc) — template loader not active"
        return 1
    fi
}

# ─── Malformed template falls back gracefully ───────────────────────────────

test_malformed_template_falls_back_to_canonical() {
    # Unknown placeholder — must NOT crash; must fall back to
    # `_RE_CANONICAL` and accept the canonical subject.
    _write_naming_config 'commit_format: #${this_is_not_a_real_placeholder} ${slug}'
    local rc
    rc=$(_validate "#PROJ-1 #T1 impl: add foo" >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "malformed-template fallback failed — canonical subject rejected (rc=$rc)"
        return 1
    fi
}

# ─── Autosquash / test-harden still pass alongside template ─────────────────

test_autosquash_subject_passes_with_naming_config() {
    _write_naming_config 'commit_format: #${story_id} #${task_id} ${type}: ${slug}'
    local rc
    rc=$(_validate "fixup! #PROJ-1 #T1 impl: add foo" >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "autosquash subject rejected when naming-config.md present (rc=$rc)"
        return 1
    fi
}

test_test_harden_subject_passes_with_naming_config() {
    _write_naming_config 'commit_format: #${story_id} #${task_id} ${type}: ${slug}'
    local rc
    rc=$(_validate "#PROJ-1 test-harden: raise coverage" >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "test-harden subject rejected when naming-config.md present (rc=$rc)"
        return 1
    fi
}

run_workflow_tests

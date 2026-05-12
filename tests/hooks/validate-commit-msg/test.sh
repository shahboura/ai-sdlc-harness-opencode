#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

HOOK="$(repo_root)/scripts/validate-commit-msg.sh"

# ── Allowed (canonical) ──────────────────────────────────────────────────────

test_allow_canonical_numeric_story() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit -m "#123456 #T1: add token endpoint"')"
}

test_allow_canonical_jira_story() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit -m "#PROJ-123 #T2: handle 401 from upstream"')"
}

test_allow_canonical_slug_story_dotted() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit -m "#auth.feature #T-TEST-AuthService: cover refresh-token path"')"
}

test_allow_tdd_test_suffix() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit -m "#123 #T1 test: add red contract test"')"
}

test_allow_tdd_impl_suffix() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit -m "#123 #T1 impl: make contract pass"')"
}

test_allow_test_harden_phase5() {
    # Phase 5 exception: no Task ID. This was missing from the previous regex.
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit -m "#123 test-harden: add integration tests"')"
}

test_allow_autosquash_fixup() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit --fixup HEAD~1')"
}

test_allow_fixup_subject_literal() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit -m "fixup! #123 #T1: prior subject"')"
}

test_allow_proper_noun_caps_in_description() {
    # Previously rejected because of the "starts-lowercase" rule.
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit -m "#123 #T1: AWS OAuth flow wired up"')"
}

# ── Command-shape coverage (the actual parser holes) ────────────────────────

test_allow_git_C_form() {
    # `git -C path commit ...` — the orchestrator's primary form.
    # The OLD regex was anchored to `^\s*git\s+commit` and missed this.
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git -C /tmp/repo commit -m "#123 #T1: foo"')"
}

test_allow_git_c_config_form() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git -c user.email=x@y commit -m "#123 #T1: foo"')"
}

test_allow_chained_cd_form() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'cd /tmp/repo && git commit -m "#123 #T1: foo"')"
}

test_allow_subshell_form() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload '(cd /tmp/repo; git commit -m "#123 #T1: foo")')"
}

test_allow_env_var_prefix() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'GIT_AUTHOR_DATE=2026-01-01 git commit -m "#123 #T1: foo"')"
}

test_allow_message_equals_form() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit --message="#123 #T1: foo"')"
}

test_allow_message_space_form() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit --message "#123 #T1: foo"')"
}

test_allow_heredoc_subject() {
    local cmd
    cmd='git commit -m "$(cat <<EOF
#123 #T1: heredoc subject

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"'
    assert_hook_allows "$HOOK" "$(mk_bash_payload "$cmd")"
}

test_allow_indented_heredoc() {
    local cmd
    cmd='git commit -m "$(cat <<-EOF
	#123 #T1: indented heredoc
	EOF
)"'
    assert_hook_allows "$HOOK" "$(mk_bash_payload "$cmd")"
}

# ── Non-commit commands ──────────────────────────────────────────────────────

test_allow_git_status() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git status')"
}

test_allow_git_push() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git push origin main')"
}

test_allow_unrelated_command() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'echo hello && ls -la')"
}

# ── Blocks ───────────────────────────────────────────────────────────────────

test_block_missing_task_id() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'git commit -m "#123: only story id"')" \
        "does not match the harness convention"
}

test_block_missing_story_id() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'git commit -m "add a thing"')" \
        "does not match the harness convention"
}

test_block_lowercase_no_hash() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'git commit -m "123 T1: missing hash prefix"')" \
        "does not match the harness convention"
}

test_block_message_via_F_file_invalid() {
    # The hook reads the file; if file doesn't exist, message can't be
    # determined — fail closed.
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'git commit -F /nonexistent/path/that/should/not/exist')" \
        "could not extract a commit message"
}

test_block_second_m_via_git_C() {
    # Bypass attempt: valid first -m, garbage second -m. The OLD regex
    # only captured the first -m and let the rest through silently.
    # Now multi-m values are joined; second one shows up in body, but
    # the subject check is on line 1 which is the first -m — so the
    # subject is still validated. The bypass therefore fails-safe here
    # because the subject check IS the security-relevant gate.
    # We accept this case (subject is valid) — kept as a documentation
    # test that captures intended behaviour.
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload 'git -C /repo commit -m "#123 #T1: valid" -m "second body line not in subject"')"
}

test_block_bypass_via_second_m_with_invalid_first() {
    # If the FIRST -m is invalid but a later -m is valid, the
    # rewritten parser refuses (subject = first line of joined
    # messages, which is the invalid first -m).
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'git commit -m "tricky bypass" -m "#123 #T1: valid"')" \
        "does not match the harness convention"
}

test_allow_allow_empty_message() {
    # Explicitly empty messages pass through; that's a git feature.
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload 'git commit --allow-empty-message --no-edit')"
}

# Workspace gate

test_allow_outside_workspace() {
    # When NOT in a harness workspace, the hook should exit 0 silently
    # so it doesn't interfere with unrelated sessions.
    local cmd_payload
    cmd_payload="$(mk_bash_payload 'git commit -m "anything goes outside workspace"')"
    # Override _setup_workspace's cd by working in /tmp directly.
    local result
    result="$(printf '%s' "$cmd_payload" | (cd /tmp && "$HOOK") 2>&1)"
    local rc=$?
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0 outside workspace, got $rc; output: $result"
        return 1
    fi
}

run_all_tests

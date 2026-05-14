#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

HOOK="$(repo_root)/scripts/squash-merge-verify.sh"

# Set up a minimal git repo with a feature branch and a staged change.
# Returns the repo path on stdout.
mk_repo_with_staged_changes() {
    local repo
    repo="$(mktemp -d -t merge-verify.XXXXXX)"
    (
        cd "$repo"
        git init -q -b main >/dev/null
        git config user.email tester@example.com
        git config user.name Tester
        printf 'hello\n' > a.txt
        git add a.txt
        git commit -q -m '#x #T0: initial'
        # Pretend a squash-merge just staged a file.
        printf 'new content\n' > b.txt
        git add b.txt
    )
    printf '%s' "$repo"
}

mk_clean_repo() {
    local repo
    repo="$(mktemp -d -t merge-verify-clean.XXXXXX)"
    (
        cd "$repo"
        git init -q -b main >/dev/null
        git config user.email tester@example.com
        git config user.name Tester
        printf 'hello\n' > a.txt
        git add a.txt
        git commit -q -m '#x #T0: initial'
    )
    printf '%s' "$repo"
}

# Run hook, capturing all output.
_run_hook_capture() {
    local payload="$1"
    (
        cd "$FAKE_WORKSPACE"
        printf '%s' "$payload" | "$HOOK" 2>&1
    )
}

# ── Non-merge commands pass through ─────────────────────────────────────────

test_passthrough_git_status() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git status')"
}

test_passthrough_git_commit() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git commit -m foo')"
}

test_passthrough_non_squash_merge() {
    assert_hook_allows "$HOOK" "$(mk_bash_payload 'git merge feature')"
}

# ── Success: changes staged ─────────────────────────────────────────────────

test_success_squash_merge_with_staged_changes() {
    local repo
    repo="$(mk_repo_with_staged_changes)"
    trap "rm -rf '$repo'" RETURN
    local payload
    payload="$(mk_bash_payload "git -C $repo merge --squash feature")"
    local out
    out="$(_run_hook_capture "$payload")"
    if ! printf '%s' "$out" | grep -qF 'Squash-merge verified'; then
        _fail "expected success message, got: $out"
        return 1
    fi
}

# Same scenario, but with `cd && git merge --squash` form
test_success_squash_merge_chained_cd() {
    local repo
    repo="$(mk_repo_with_staged_changes)"
    trap "rm -rf '$repo'" RETURN
    local payload
    payload="$(mk_bash_payload "cd $repo && git merge --squash feature")"
    local out
    out="$(_run_hook_capture "$payload")"
    if ! printf '%s' "$out" | grep -qF 'Squash-merge verified'; then
        _fail "expected success message for chained form, got: $out"
        return 1
    fi
}

# `git -c <cfg> merge --squash` form
test_success_squash_merge_with_c_config() {
    local repo
    repo="$(mk_repo_with_staged_changes)"
    trap "rm -rf '$repo'" RETURN
    local payload
    payload="$(mk_bash_payload "git -c gpg.sign=false -C $repo merge --squash feature")"
    local out
    out="$(_run_hook_capture "$payload")"
    if ! printf '%s' "$out" | grep -qF 'Squash-merge verified'; then
        _fail "expected success message with -c config flag, got: $out"
        return 1
    fi
}

# Env-var prefix form
test_success_squash_merge_with_env_prefix() {
    local repo
    repo="$(mk_repo_with_staged_changes)"
    trap "rm -rf '$repo'" RETURN
    local payload
    payload="$(mk_bash_payload "GIT_AUTHOR_NAME=test git -C $repo merge --squash feature")"
    local out
    out="$(_run_hook_capture "$payload")"
    if ! printf '%s' "$out" | grep -qF 'Squash-merge verified'; then
        _fail "expected success message with env prefix, got: $out"
        return 1
    fi
}

# ── Empty result: no staged changes ─────────────────────────────────────────

test_warning_no_staged_changes_with_branch() {
    local repo
    repo="$(mk_clean_repo)"
    trap "rm -rf '$repo'" RETURN
    # Use --squash with a branch name so the parser knows the branch arg.
    local payload
    payload="$(mk_bash_payload "git -C $repo merge --squash nonexistent-branch")"
    # Should exit 2 (warning to model) when staged_count == 0 AND we know the branch.
    local result rc
    result="$(printf '%s' "$payload" | (cd "$FAKE_WORKSPACE" && "$HOOK") 2>&1)"
    rc=$?
    if [ "$rc" != "2" ]; then
        _fail "expected exit 2 for empty result, got rc=$rc; output: $result"
        return 1
    fi
    if ! printf '%s' "$result" | grep -qF 'no staged changes'; then
        _fail "expected 'no staged changes' message, got: $result"
        return 1
    fi
}

# ── git -C path that doesn't exist: graceful degradation ────────────────────

test_no_crash_on_nonexistent_repo_path() {
    # OLD bug: `[ "$STAGED_COUNT" -gt 0 ]` would syntax-error when git -C
    # returned empty. Confirm we don't crash.
    local payload
    payload="$(mk_bash_payload 'git -C /nonexistent/path/to/repo merge --squash feature')"
    local rc
    rc=$(printf '%s' "$payload" | (cd "$FAKE_WORKSPACE" && "$HOOK") >/dev/null 2>&1; echo $?)
    # Either 0 or 2 is acceptable; what we want is "doesn't crash with rc>=3".
    if [ "$rc" -ge 3 ]; then
        _fail "hook crashed on nonexistent repo path (rc=$rc); should degrade gracefully"
        return 1
    fi
}

# ── Workspace gate ─────────────────────────────────────────────────────────

test_passthrough_outside_workspace() {
    local payload
    payload="$(mk_bash_payload 'git merge --squash feature')"
    local rc
    rc=$(printf '%s' "$payload" | (cd /tmp && "$HOOK") >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0 outside workspace, got $rc"
        return 1
    fi
}

run_all_tests

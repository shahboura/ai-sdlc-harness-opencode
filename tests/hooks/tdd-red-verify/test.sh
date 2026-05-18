#!/usr/bin/env bash
# Hook: tdd-red-verify
# Event: PostToolUse on Bash
# Policy: fail-CLOSED (exit 2 blocks the next step) on a vacuous-test or
#         broken-impl flip; fail-OPEN on every non-`impl:` commit, every
#         non-Bash payload, and every unresolvable workspace.
#
# These tests pin the *no-op surface* — the conditions under which the hook
# correctly stays silent. The deep red→green replay path requires a fixture
# git repo with two commits + a language-config.md test_cmd; that surface is
# covered indirectly by M-20's existing tests/skills/ outline. Here we lock
# the entry-point guards so future changes can't accidentally widen them.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

HOOK="$(repo_root)/scripts/tdd-red-verify.sh"

# ── no-op when the tool isn't Bash ─────────────────────────────────────────

test_noop_when_tool_is_not_bash() {
    local payload
    payload="$(mk_edit_payload 'foo.py' 'old' 'new')"
    assert_hook_allows "$HOOK" "$payload"
}

# ── no-op for Bash commands that aren't git commits ────────────────────────

test_noop_on_plain_bash_command() {
    local payload
    payload="$(mk_bash_payload 'ls -la')"
    assert_hook_allows "$HOOK" "$payload"
}

test_noop_on_git_status() {
    local payload
    payload="$(mk_bash_payload 'git status')"
    assert_hook_allows "$HOOK" "$payload"
}

# ── no-op for git commits whose subject does NOT start with `impl:` ────────

test_noop_on_test_commit() {
    # Tester's red-test commit precedes the developer's impl commit — the
    # hook must not run on the tester commit.
    local payload
    payload="$(mk_bash_payload 'git commit -m "#STORY #T1 test: add failing case"')"
    assert_hook_allows "$HOOK" "$payload"
}

test_noop_on_refactor_commit() {
    local payload
    payload="$(mk_bash_payload 'git commit -m "refactor: extract helper"')"
    assert_hook_allows "$HOOK" "$payload"
}

test_noop_on_docs_commit() {
    local payload
    payload="$(mk_bash_payload 'git commit -m "docs(readme): clarify gates"')"
    assert_hook_allows "$HOOK" "$payload"
}

# ── no-op when payload is missing required fields ──────────────────────────

test_noop_on_empty_command() {
    local payload='{"tool_name":"Bash","tool_input":{}}'
    assert_hook_allows "$HOOK" "$payload"
}

test_noop_on_malformed_payload() {
    # `_main` returns 0 on JSON decode failure.
    local payload='not-json'
    assert_hook_allows "$HOOK" "$payload"
}

# ── impl: commit OUTSIDE a git repo — fail-open via _detect_repo_from_cmd ─

test_noop_impl_commit_when_no_git_repo_in_workspace() {
    # FAKE_WORKSPACE is *not* a git repo (no .git dir). `_detect_repo_from_cmd`
    # returns None, the hook returns 0. This pins the fail-open path so the
    # hook does not block harness internals when developers run `impl:` style
    # commits in non-harness contexts.
    local payload
    payload="$(mk_bash_payload 'git commit -m "#S1 #T1 impl: add user-service handler"')"
    assert_hook_allows "$HOOK" "$payload"
}

# ── impl: commit with an explicit -C path that doesn't exist — fail-open ──

test_noop_impl_commit_when_repo_path_missing() {
    local payload
    payload="$(mk_bash_payload 'git -C /nonexistent/repo commit -m "#S1 #T1 impl: x"')"
    assert_hook_allows "$HOOK" "$payload"
}

run_all_tests

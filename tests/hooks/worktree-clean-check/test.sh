#!/usr/bin/env bash
# Hook: worktree-clean-check
# Event: SubagentStop
# Policy: fail-CLOSED when:
#         - The status block parses cleanly
#         - Agent ∈ {developer, tester}
#         - Outcome == SUCCESS exactly
#         - Worktree / Repo path resolves to a real git repo
#         - `git status --porcelain` returns non-empty
#         Fail-OPEN otherwise (planner/reviewer, no block, unresolvable path,
#         PARTIAL/BLOCKED/FAILED — those have their own reason fields).
#
# Covers CC-02.1: orchestrator must NOT commit on behalf of the agent.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

HOOK="$(repo_root)/scripts/worktree-clean-check.sh"

# ── Git-repo fixtures ─────────────────────────────────────────────────────

# Initialise a one-commit git repo at the given path under FAKE_WORKSPACE
# and echo the absolute path. The repo starts clean.
mk_clean_repo() {
    local rel="$1"
    local path="$FAKE_WORKSPACE/$rel"
    mkdir -p "$path"
    git -C "$path" init -q -b main
    git -C "$path" config user.email 'test@example.com'
    git -C "$path" config user.name 'Test'
    printf 'seed\n' >"$path/README.md"
    git -C "$path" add README.md
    git -C "$path" -c commit.gpgsign=false commit -q -m 'seed'
    printf '%s' "$path"
}

# Make a fixture repo dirty by leaving an untracked file.
make_dirty() {
    local path="$1"
    printf 'uncommitted\n' >"$path/scratch.txt"
}

# Build a SubagentStop payload whose `response` text ends with the given
# status block.
mk_payload() {
    local block="$1"
    mk_subagentstop_payload "Some prose preamble.

$block"
}

# ── out-of-scope agents — pass regardless of worktree state ───────────────

test_allow_when_agent_is_planner() {
    local block='📋 AGENT STATUS
- Agent: ai-sdlc-planner
- Outcome: SUCCESS
- Next action: handoff to orchestrator'
    assert_hook_allows "$HOOK" "$(mk_payload "$block")"
}

test_allow_when_agent_is_reviewer() {
    local block='📋 AGENT STATUS
- Agent: ai-sdlc-reviewer
- Verdict: APPROVED
- Next action: proceed to merge'
    assert_hook_allows "$HOOK" "$(mk_payload "$block")"
}

# ── non-SUCCESS outcomes — pass (their own reason field carries the signal) ─

test_allow_when_developer_partial() {
    local repo
    repo="$(mk_clean_repo 'repo-partial')"
    make_dirty "$repo"
    local block="📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Repo path: $repo
- Outcome: PARTIAL
- Blockers: stopped at soft-cap
- Next action: re-invoke developer"
    assert_hook_allows "$HOOK" "$(mk_payload "$block")"
}

test_allow_when_developer_blocked() {
    local block='📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Outcome: BLOCKED
- Blockers: missing dependency
- Next action: surface to human'
    assert_hook_allows "$HOOK" "$(mk_payload "$block")"
}

# ── missing or unparseable status block — pass (delegated to agent-status-check) ─

test_allow_when_no_status_block() {
    assert_hook_allows "$HOOK" "$(mk_subagentstop_payload 'Plain text response with no status block.')"
}

# ── unresolvable paths — pass ─────────────────────────────────────────────

test_allow_when_worktree_is_direct_branch_and_no_repo_path() {
    local block='📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Worktree: not used (direct branch)
- Outcome: SUCCESS
- Next action: ready for review'
    assert_hook_allows "$HOOK" "$(mk_payload "$block")"
}

test_allow_when_repo_path_does_not_exist() {
    local block='📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Repo path: /tmp/does-not-exist-12345
- Outcome: SUCCESS
- Next action: ready for review'
    assert_hook_allows "$HOOK" "$(mk_payload "$block")"
}

# ── developer SUCCESS + clean repo — pass ─────────────────────────────────

test_allow_when_developer_success_and_worktree_clean() {
    local repo
    repo="$(mk_clean_repo 'repo-clean')"
    local block="📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Repo: repoA
- Repo path: $repo
- Worktree: $repo
- Worktree branch: feat-x
- Build result: PASS (0 warnings)
- Build attempts: 1
- Commit: abc1234
- Files changed: README.md
- Self-review: PASS
- Outcome: SUCCESS
- Concerns: none
- Blockers: none
- Next action: ready for review"
    assert_hook_allows "$HOOK" "$(mk_payload "$block")"
}

# ── developer SUCCESS + dirty worktree — BLOCK ────────────────────────────

test_block_when_developer_success_and_worktree_dirty() {
    local repo
    repo="$(mk_clean_repo 'repo-dirty-dev')"
    make_dirty "$repo"
    local block="📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Repo path: $repo
- Worktree: $repo
- Outcome: SUCCESS
- Next action: ready for review"
    assert_hook_blocks "$HOOK" "$(mk_payload "$block")" 'worktree is dirty'
}

test_block_when_tester_success_and_worktree_dirty() {
    local repo
    repo="$(mk_clean_repo 'repo-dirty-test')"
    make_dirty "$repo"
    local block="📋 AGENT STATUS
- Agent: ai-sdlc-tester
- Repo path: $repo
- Worktree: $repo
- Outcome: SUCCESS
- Next action: handoff"
    assert_hook_blocks "$HOOK" "$(mk_payload "$block")" 'worktree is dirty'
}

# ── direct-branch tester + dirty repo (path resolved via Repo path) — BLOCK ─

test_block_when_direct_branch_repo_path_dirty() {
    local repo
    repo="$(mk_clean_repo 'repo-dirty-direct')"
    make_dirty "$repo"
    local block="📋 AGENT STATUS
- Agent: ai-sdlc-developer
- Repo path: $repo
- Worktree: not used (direct branch)
- Outcome: SUCCESS
- Next action: handoff"
    assert_hook_blocks "$HOOK" "$(mk_payload "$block")" 'worktree is dirty'
}

run_all_tests

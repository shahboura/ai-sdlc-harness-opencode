#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

HOOK="$(repo_root)/scripts/bash-write-guard.sh"

# ── Always-on rule 1: writes under ai/ are forbidden from Bash ───────────────

test_block_redirect_to_ai_tracker() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo new-row >> ai/tasks/2026-05-12-story-tracker.md')" \
        "harness-owned path"
}

test_block_redirect_to_ai_plan() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'cat plan.txt > ai/plans/foo.md')" \
        "harness-owned path"
}

test_block_redirect_with_dotslash() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo x >> ./ai/tasks/x.md')" \
        "harness-owned path"
}

test_block_tee_to_ai() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo data | tee ai/tasks/x.md')" \
        "harness-owned path"
}

test_block_cp_to_ai() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'cp /tmp/staging.md ai/tasks/story.md')" \
        "harness-owned path"
}

test_block_mv_to_ai() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'mv /tmp/staging.md ai/plans/plan.md')" \
        "harness-owned path"
}

test_block_inline_redirect_no_space() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo x >ai/tasks/x.md')" \
        "harness-owned path"
}

# ── Always-on rule 2: sensitive file targets ─────────────────────────────────

test_block_redirect_to_env() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo SECRET=1 > .env')" \
        "sensitive file"
}

test_block_redirect_to_env_local() {
    # The OLD sensitive-file-guard regex used `\.env$`, missing this.
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo SECRET=1 > .env.local')" \
        "sensitive file"
}

test_block_redirect_to_env_production() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'cat /tmp/prod-config > .env.production')" \
        "sensitive file"
}

test_block_tee_to_pem() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo data | tee key.pem')" \
        "sensitive file"
}

test_block_cp_to_id_rsa() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'cp /tmp/key id_rsa')" \
        "sensitive file"
}

test_block_redirect_to_tfstate() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'cat backup > terraform.tfstate')" \
        "sensitive file"
}

test_block_dd_to_keyfile() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'dd if=/tmp/x of=secret.key bs=512')" \
        "sensitive file"
}

# ── Subagent-aware rule 3: reviewer is read-only ─────────────────────────────

test_block_reviewer_any_redirect() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo "review notes" > /tmp/notes.md' '{"agent_type":"reviewer"}')" \
        "reviewer is read-only"
}

test_block_reviewer_cp_to_tmp() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'cp /tmp/a.txt /tmp/b.txt' '{"agent_type":"reviewer"}')" \
        "reviewer is read-only"
}

test_block_reviewer_tee_anywhere() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo x | tee out.txt' '{"agent_type":"reviewer"}')" \
        "reviewer is read-only"
}

test_allow_reviewer_grep() {
    # Reviewer reads — that's fine.
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload 'grep -r TODO src/' '{"agent_type":"reviewer"}')"
}

test_allow_reviewer_git_log() {
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload 'git log --oneline -10' '{"agent_type":"reviewer"}')"
}

test_block_reviewer_with_namespaced_agent_type() {
    # Real Claude Code subagent agent_type values are namespaced like
    # `plugin:dir:name` — the canonical form for this harness's reviewer is
    # `ai-sdlc-harness:reviewer:reviewer`. The identity check must normalise
    # to the last segment.
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo notes > /tmp/scratch' '{"agent_type":"ai-sdlc-harness:reviewer:reviewer"}')" \
        "reviewer is read-only"
}

test_block_planner_with_namespaced_agent_type() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo x > /home/u/scratch' '{"agent_type":"ai-sdlc-harness:planner:planner"}')" \
        "planner can write only under ai/"
}

# ── Subagent-aware rule 3: planner only writes under ai/ ─────────────────────

test_block_planner_write_outside_ai() {
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo notes > /home/user/scratch.md' '{"subagent_name":"planner"}')" \
        "planner can write only under ai/"
}

test_allow_planner_write_to_ai() {
    # Planner is explicitly permitted to mutate ai/ via shell (e.g.
    # tracker templating). This is the inverse of rule 1 for planner only.
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload 'echo new-row >> ai/tasks/2026-05-12-tracker.md' '{"subagent_name":"planner"}')"
}

test_allow_planner_write_to_tmp() {
    # Tempdirs are scratch — fine.
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload 'echo scratch > /tmp/draft.txt' '{"subagent_name":"planner"}')"
}

# ── Always-on negative cases (allowed) ───────────────────────────────────────

test_allow_redirect_to_dev_null() {
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload 'some-noisy-command > /dev/null 2>&1')"
}

test_allow_redirect_to_tmp() {
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload 'echo scratch > /tmp/scratch.txt')"
}

test_allow_redirect_to_repo_source() {
    # Developer writing to repo source is fine — that's their job.
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload 'echo content > src/utils/foo.ts')"
}

test_allow_pure_read_command() {
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload 'cat file.txt | grep needle')"
}

test_allow_pipe_chain_no_writes() {
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload 'ls -la | wc -l')"
}

test_allow_outside_workspace() {
    # Workspace gate. Override the harness's setup by running from /tmp.
    local payload
    payload="$(mk_bash_payload 'echo x > .env')"
    local rc
    rc=$(printf '%s' "$payload" | (cd /tmp && "$HOOK") >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0 outside workspace, got $rc"
        return 1
    fi
}

# ── Heredoc safety ───────────────────────────────────────────────────────────

test_block_heredoc_to_ai() {
    local cmd
    cmd='cat > ai/tasks/x.md <<EOF
content
EOF'
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload "$cmd")" \
        "harness-owned path"
}

test_allow_heredoc_to_tmp() {
    local cmd
    cmd='cat > /tmp/scratch.txt <<EOF
content
EOF'
    assert_hook_allows "$HOOK" \
        "$(mk_bash_payload "$cmd")"
}

# ── Path normalisation: relative-traversal loophole ─────────────────────────

test_block_dotdot_traversal_to_ai() {
    # `foo/../ai/tasks/x.md` normalises to `ai/tasks/x.md` — must block.
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo x > foo/../ai/tasks/x.md')" \
        "harness-owned path"
}

test_block_dotdot_traversal_to_sensitive() {
    # `bar/../.env` normalises to `.env` — must block.
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload 'echo x > bar/../.env')" \
        "sensitive file"
}

# ── Path normalisation: symlink resolution ──────────────────────────────────

test_block_symlink_into_ai() {
    # Set up a symlink whose name looks innocent but points into ai/.
    mkdir -p "$FAKE_WORKSPACE/ai/tasks"
    : > "$FAKE_WORKSPACE/ai/tasks/real.md"
    ln -s "$FAKE_WORKSPACE/ai/tasks/real.md" "$FAKE_WORKSPACE/innocent.md"
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload "echo x > $FAKE_WORKSPACE/innocent.md")" \
        "harness-owned path"
}

test_block_symlink_to_sensitive() {
    # Symlink with an innocent basename pointing at a sensitive target.
    : > "$FAKE_WORKSPACE/.env"
    ln -s "$FAKE_WORKSPACE/.env" "$FAKE_WORKSPACE/notes.txt"
    assert_hook_blocks "$HOOK" \
        "$(mk_bash_payload "echo SECRET=1 > $FAKE_WORKSPACE/notes.txt")" \
        "sensitive file"
}

run_all_tests

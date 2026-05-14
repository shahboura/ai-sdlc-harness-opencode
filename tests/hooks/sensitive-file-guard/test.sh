#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

HOOK="$(repo_root)/scripts/sensitive-file-guard.sh"

# ── Blocked patterns (the broadened deny-list) ──────────────────────────────

test_block_dot_env() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/repo/.env' 'KEY=val')" "sensitive file"
}

test_block_env_local() {
    # The OLD regex anchored on \.env$ and missed this.
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/repo/.env.local' 'x')" "sensitive file"
}

test_block_env_production() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/repo/.env.production' 'x')" "sensitive file"
}

test_block_pem_via_edit() {
    assert_hook_blocks "$HOOK" "$(mk_edit_payload '/repo/server.pem' 'a' 'b')" "sensitive file"
}

test_block_key_via_multiedit() {
    # OLD matcher didn't include MultiEdit at all.
    assert_hook_blocks "$HOOK" \
        "$(mk_multiedit_payload '/repo/private.key' '[{"old_string":"a","new_string":"b"}]')" \
        "sensitive file"
}

test_block_p12() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/repo/cert.p12' 'x')" "sensitive file"
}

test_block_pfx() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/repo/cert.pfx' 'x')" "sensitive file"
}

test_block_kdbx() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/home/user/db.kdbx' 'x')" "sensitive file"
}

test_block_id_rsa() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/home/user/.ssh/id_rsa' 'x')" "sensitive file"
}

test_block_id_ed25519() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/home/user/.ssh/id_ed25519' 'x')" "sensitive file"
}

test_block_tfstate() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/infra/terraform.tfstate' 'x')" "sensitive file"
}

test_block_tfstate_backup() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/infra/terraform.tfstate.backup' 'x')" "sensitive file"
}

test_block_npmrc() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/repo/.npmrc' 'x')" "sensitive file"
}

test_block_netrc() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/home/user/.netrc' 'x')" "sensitive file"
}

test_block_credentials() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/aws/credentials' 'x')" "sensitive file"
}

test_block_secrets_yaml() {
    assert_hook_blocks "$HOOK" "$(mk_write_payload '/repo/secrets.yaml' 'x')" "sensitive file"
}

test_block_notebook_edit_to_sensitive() {
    # NotebookEdit was not in the OLD matcher.
    assert_hook_blocks "$HOOK" \
        "$(mk_notebook_payload '/repo/keys/server.pem')" \
        "sensitive file"
}

# ── Allowed (negative cases) ────────────────────────────────────────────────

test_allow_normal_source_file() {
    assert_hook_allows "$HOOK" "$(mk_write_payload '/repo/src/index.ts' 'x')"
}

test_allow_env_d_directory_not_basename() {
    # The pattern matches basename only — `.env.d/` is a directory, files
    # *inside* should pass unless their own basenames match.
    assert_hook_allows "$HOOK" "$(mk_write_payload '/repo/.env.d/README.md' 'x')"
}

test_allow_requirements_env_substring() {
    # `requirements.env` should match (`*.env`) — keep this as a positive
    # block to document the substring rule.
    assert_hook_blocks "$HOOK" \
        "$(mk_write_payload '/repo/requirements.env' 'x')" \
        "sensitive file"
}

test_allow_outside_workspace() {
    local payload
    payload="$(mk_write_payload '/repo/.env' 'x')"
    local rc
    rc=$(printf '%s' "$payload" | (cd /tmp && "$HOOK") >/dev/null 2>&1; echo $?)
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0 outside workspace, got $rc"
        return 1
    fi
}

run_all_tests

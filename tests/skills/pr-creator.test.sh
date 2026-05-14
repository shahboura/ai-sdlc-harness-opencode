#!/usr/bin/env bash
# Doc-grep regression for the pr-creator idempotency + draft-PR slice.
# Catches future edits that remove the find_for_branch step, drop PR_MODE
# context block plumbing, re-add the mcp__zoho__* allow-list, or strip
# the auth-failure copy.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PR_CREATOR="$REPO_ROOT/skills/pr-creator/SKILL.md"
CREATE_PR="$REPO_ROOT/skills/dev-workflow/commands/create-pr.md"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

# --- pr-creator/SKILL.md ----------------------------------------------------

# 1. Step 0 idempotency exists and references pr.find_for_branch.
if grep -qE '^### 0\. Idempotency Check' "$PR_CREATOR"; then
    _pass 'pr-creator declares Step 0 (Idempotency Check)'
else
    _fail 'pr-creator declares Step 0 (Idempotency Check)' 'no `### 0. Idempotency Check` heading'
fi

if grep -q 'pr\.find_for_branch' "$PR_CREATOR"; then
    _pass 'pr-creator Step 0 routes through pr.find_for_branch capability'
else
    _fail 'pr-creator Step 0 routes through pr.find_for_branch capability' \
        'no mention of pr.find_for_branch — Step 0 must use the capability declared in skills/providers/shared/capabilities.md'
fi

# 2. Reuse/Fail prompt must be present.
if grep -qE '\[1\] Reuse' "$PR_CREATOR" && grep -qE '\[2\] Fail' "$PR_CREATOR"; then
    _pass 'pr-creator Step 0 presents Reuse / Fail prompt'
else
    _fail 'pr-creator Step 0 presents Reuse / Fail prompt' \
        'missing [1] Reuse / [2] Fail options — the human must choose, no auto-pick'
fi

# 3. Default branch is sourced from repos-metadata.md explicitly.
if grep -q 'repos-metadata\.md' "$PR_CREATOR" && grep -qE 'Default Branch' "$PR_CREATOR"; then
    _pass 'pr-creator reads default branch from repos-metadata.md'
else
    _fail 'pr-creator reads default branch from repos-metadata.md' \
        'no explicit reference to repos-metadata.md `Default Branch` — must not assume main'
fi

# 4. mcp__zoho__* dropped from allowed-tools.
if grep -E '^allowed-tools:.*mcp__zoho__' "$PR_CREATOR" >/dev/null; then
    _fail 'pr-creator drops mcp__zoho__* from allowed-tools' \
        'allow-list still includes mcp__zoho__* — pr-creator never calls Zoho'
else
    _pass 'pr-creator drops mcp__zoho__* from allowed-tools'
fi

# 5. PR_MODE context block read at Step 0.
if grep -qE '^PR_MODE:' "$PR_CREATOR" && grep -qE 'standard.*draft|draft.*standard' "$PR_CREATOR"; then
    _pass 'pr-creator reads PR_MODE context block (standard | draft)'
else
    _fail 'pr-creator reads PR_MODE context block (standard | draft)' \
        'missing `PR_MODE:` context block and the standard|draft enum'
fi

# 6. Draft mode applies the per-adapter flag in Step 6.
# Check at least one adapter wiring carries the flag.
if grep -qE 'isDraft=' "$PR_CREATOR" \
   && grep -qE 'draft=<true if PR_MODE=draft' "$PR_CREATOR" \
   && grep -qE '\[--draft\]' "$PR_CREATOR"; then
    _pass 'pr-creator Step 6 wires the draft flag per adapter (ADO + GitHub/GitLab MCP + CLI)'
else
    _fail 'pr-creator Step 6 wires the draft flag per adapter' \
        'expected isDraft / draft= / [--draft] across ADO, MCP, and CLI adapter blocks'
fi

# 7. Auth-failure copy points at the adapter's Prerequisites section.
if grep -qE 'Auth-failure copy|authentication failure' "$PR_CREATOR" \
   && grep -qE '\*\*Prerequisites\*\* section' "$PR_CREATOR"; then
    _pass 'pr-creator emits auth-failure copy pointing at Prerequisites'
else
    _fail 'pr-creator emits auth-failure copy pointing at Prerequisites' \
        'missing the auth-failure section that names the adapter Prerequisites'
fi

# --- create-pr.md (Phase 6 GATE) -------------------------------------------

# 8. GATE prompt is multi-choice (APPROVED / DRAFT / CHANGES).
if grep -qE '\[1\] APPROVED' "$CREATE_PR" \
   && grep -qE '\[2\] DRAFT' "$CREATE_PR" \
   && grep -qE '\[3\] CHANGES' "$CREATE_PR"; then
    _pass 'create-pr.md Step 3 GATE is multi-choice (APPROVED / DRAFT / CHANGES)'
else
    _fail 'create-pr.md Step 3 GATE is multi-choice (APPROVED / DRAFT / CHANGES)' \
        'expected [1] APPROVED, [2] DRAFT, [3] CHANGES in the gate prompt'
fi

# 9. Step 7 passes PR_MODE into pr-creator.
if grep -qE 'PR_MODE: <standard \| draft>' "$CREATE_PR"; then
    _pass 'create-pr.md Step 7 passes PR_MODE into pr-creator'
else
    _fail 'create-pr.md Step 7 passes PR_MODE into pr-creator' \
        'pr-creator invocation must include `PR_MODE: <standard | draft>` context block'
fi

# 10. Step 5 maps the human choice to PR_MODE.
if grep -qE 'PR_MODE.*standard' "$CREATE_PR" && grep -qE 'PR_MODE.*draft' "$CREATE_PR"; then
    _pass 'create-pr.md Step 5 maps human choice to PR_MODE'
else
    _fail 'create-pr.md Step 5 maps human choice to PR_MODE' \
        'expected Step 5 to declare the choice → PR_MODE mapping (standard / draft)'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

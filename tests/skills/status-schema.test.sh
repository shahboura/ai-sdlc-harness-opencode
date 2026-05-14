#!/usr/bin/env bash
# Doc-grep regression: every agent file references the canonical
# status-schema.md and every status-block example contains the required
# fields per the schema. The hook enforces a small floor at runtime; this
# suite enforces the per-mode contract at build time.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="$REPO_ROOT/agents/shared/status-schema.md"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

# All agent files must reference the schema so renames stay synchronised.
_assert_references_schema() {
    local label="$1"
    local file="$2"
    if grep -qF 'agents/shared/status-schema.md' "$file"; then
        _pass "$label references status-schema.md"
    else
        _fail "$label references status-schema.md" "no mention of agents/shared/status-schema.md"
    fi
}

# Assert a field name appears in a file. Strict — anchors on `- <field>:`
# in the line.
_assert_field_present() {
    local label="$1"
    local file="$2"
    local field="$3"
    if grep -Eq "^- ${field}:" "$file"; then
        _pass "$label declares \`${field}:\`"
    else
        _fail "$label declares \`${field}:\`" "no \`- ${field}:\` line in $(basename "$file")"
    fi
}

# Negative assertion — a legacy field name must NOT appear as a status-block
# field declaration. Matches `- <field>:` at line start only; descriptive
# prose mentioning the legacy name (e.g. "the legacy `test_commit:` name is
# no longer accepted") is intentionally tolerated.
_assert_field_absent() {
    local label="$1"
    local file="$2"
    local field="$3"
    if grep -Eq "^- ${field}:" "$file"; then
        _fail "$label drops legacy \`${field}:\` field" "status block still declares the legacy field"
    else
        _pass "$label drops legacy \`${field}:\` field"
    fi
}

# --- 0. The schema file itself exists and is non-trivial. ------------------
if [ -f "$SCHEMA" ] && [ "$(wc -l < "$SCHEMA")" -ge 20 ]; then
    _pass "agents/shared/status-schema.md exists"
else
    _fail "agents/shared/status-schema.md exists" "missing or too short"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi

# --- 1. Every agent file references the schema. ----------------------------
_assert_references_schema 'planner/index.md'              "$REPO_ROOT/agents/planner/index.md"
_assert_references_schema 'developer/index.md'            "$REPO_ROOT/agents/developer/index.md"
_assert_references_schema 'tester/index.md'               "$REPO_ROOT/agents/tester/index.md"
_assert_references_schema 'reviewer/index.md'             "$REPO_ROOT/agents/reviewer/index.md"
_assert_references_schema 'reviewer/pre-pr.md'            "$REPO_ROOT/agents/reviewer/pre-pr.md"
_assert_references_schema 'reviewer/pr-comment-analysis.md' "$REPO_ROOT/agents/reviewer/pr-comment-analysis.md"

# --- 2. Per-agent required fields appear in the status-block example. ------

# Planner: new fields Tracker path / Plan path declared in Phase 2.
_assert_field_present 'planner block' "$REPO_ROOT/agents/planner/index.md" 'Agent'
_assert_field_present 'planner block' "$REPO_ROOT/agents/planner/index.md" 'Tracker path'
_assert_field_present 'planner block' "$REPO_ROOT/agents/planner/index.md" 'Plan path'

# Developer.
_assert_field_present 'developer block' "$REPO_ROOT/agents/developer/index.md" 'Agent'
_assert_field_present 'developer block' "$REPO_ROOT/agents/developer/index.md" 'Worktree branch'
_assert_field_present 'developer block' "$REPO_ROOT/agents/developer/index.md" 'Commit'

# Tester: rename complete, Mode declared, no `test_commit` anywhere.
_assert_field_present 'tester block'  "$REPO_ROOT/agents/tester/index.md" 'Agent'
_assert_field_present 'tester block'  "$REPO_ROOT/agents/tester/index.md" 'Mode'
_assert_field_present 'tester block'  "$REPO_ROOT/agents/tester/index.md" 'Commit'
_assert_field_present 'tester block'  "$REPO_ROOT/agents/tester/index.md" 'Worktree branch'
_assert_field_absent  'tester'        "$REPO_ROOT/agents/tester/index.md" 'test_commit'

# Tester declares BOTH modes (auto-tdd, auto-harden) — drift catcher.
if grep -qE '^- Mode: auto-tdd' "$REPO_ROOT/agents/tester/index.md" \
   && grep -qE '^- Mode: auto-harden' "$REPO_ROOT/agents/tester/index.md"; then
    _pass 'tester declares both auto-tdd and auto-harden modes'
else
    _fail 'tester declares both auto-tdd and auto-harden modes' \
        'expected `- Mode: auto-tdd` AND `- Mode: auto-harden` lines'
fi

# Reviewer modes carry Verdict (renamed/canonicalised across all three modes).
_assert_field_present 'reviewer Phase 3/5 block' "$REPO_ROOT/agents/reviewer/index.md"               'Verdict'
_assert_field_present 'reviewer Phase 6 block'   "$REPO_ROOT/agents/reviewer/pre-pr.md"              'Verdict'
_assert_field_present 'reviewer Phase 7 block'   "$REPO_ROOT/agents/reviewer/pr-comment-analysis.md" 'Verdict'

# --- 3. engineering-principles.md has no agent-style frontmatter. ----------
if head -1 "$REPO_ROOT/agents/shared/engineering-principles.md" | grep -q '^---$'; then
    _fail 'engineering-principles strips agent frontmatter' \
        'file still starts with YAML frontmatter — strip it (it is a reference doc, not an invocable agent)'
else
    _pass 'engineering-principles strips agent frontmatter'
fi

# --- 4. Reviewer Phase 0 has dropped the commit-msg regex check. -----------
# The Phase 0 section previously had a "Commit message format" item enforcing
# the canonical regex. That check moved into validate-commit-msg.sh. Scope
# the search to the Phase 0 block only — the PR Checklist (later in the file)
# legitimately mentions the commit format as a high-level reviewer reminder.
phase0_block=$(awk '/^#### Phase 0:/,/^#### Phase A:/' "$REPO_ROOT/agents/reviewer/index.md")
if printf '%s' "$phase0_block" | grep -qE 'Commit message format|<TASK-ID>.*lowercase-description'; then
    _fail 'reviewer Phase 0 drops commit-msg regex' \
        'Phase 0 still references the canonical commit-msg regex — should be moved to validate-commit-msg.sh'
else
    _pass 'reviewer Phase 0 drops commit-msg regex'
fi

# Phase 0 must also no longer enforce sensitive-file presence — that moved
# to sensitive-file-guard.sh.
if printf '%s' "$phase0_block" | grep -qE 'Sensitive files absent|\\.env.*\\.secret.*\\.key'; then
    _fail 'reviewer Phase 0 drops sensitive-file check' \
        'Phase 0 still enforces sensitive-file detection — should be moved to sensitive-file-guard.sh'
else
    _pass 'reviewer Phase 0 drops sensitive-file check'
fi

# --- 5. develop.md's lane-state variable comment still references Commit. --
# The internal `test_commit` variable name remains (lane-state plumbing), but
# the docstring must clarify the field source is now `Commit:`.
if grep -qF "extracted from the Tester's \`Commit:\` field" "$REPO_ROOT/skills/dev-workflow/commands/develop.md"; then
    _pass 'develop.md lane-state comment names the canonical Commit field'
else
    _fail 'develop.md lane-state comment names the canonical Commit field' \
        'no mention of the Commit: source field in the test_commit lane-state comment'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

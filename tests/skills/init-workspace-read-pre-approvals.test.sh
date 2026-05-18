#!/usr/bin/env bash
# init-workspace Read pre-approvals regression: Step 3c auto-adds two classes
# of Read(...) entries to .claude/settings.json without prompting:
#   1. Read(~/.claude/plugins/**) — covers the harness plugin wherever Claude
#      Code installed it (cache/, marketplaces/<name>/, future paths).
#   2. Read(//<repo-path>/**) — one per repo in repos-paths.md (double slash
#      means filesystem-absolute in Claude Code's grammar).
#
# Pre-fix, the orchestrator and agents were prompted to confirm Read on the
# harness's own skill / command / context / agent files and on every repo
# source file, neither of which is a meaningful security decision (the user
# installed the plugin and registered the repos). Background agents stalled
# because they can't respond to permission prompts.
#
# Locks the cross-file contract:
#   permissions.md: documents both the interactive Bash flow AND the
#                   automatic Read flow with the exact entry strings,
#                   idempotency rule, and refresh semantics.
#   SKILL.md:       Step 3c description names both flows; the Reference
#                   Documents table entry covers both; the post-init
#                   summary mentions plugin + repo Read entries.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

assert_contains() {
    local file="$1" needle="$2" label="$3"
    if grep -qF -- "$needle" "$file"; then _pass "$label"; else _fail "$label" "expected to find: $needle in $(basename "$file")"; fi
}

PERMS="$REPO_ROOT/skills/init-workspace/permissions.md"
SKILL="$REPO_ROOT/skills/init-workspace/SKILL.md"

# --- 1. permissions.md declares the dual flow. ---------------------------
assert_contains "$PERMS" '## Procedure (Bash — interactive)' \
    'permissions.md retains the existing Bash interactive procedure heading'
assert_contains "$PERMS" '## Procedure (Read — automatic, no prompt)' \
    'permissions.md declares the new Read automatic procedure'
assert_contains "$PERMS" 'Read pre-approvals require **no human approval**' \
    'permissions.md states Read pre-approvals skip the prompt'

# --- 2. Plugin read entry is exact. --------------------------------------
assert_contains "$PERMS" 'Read(~/.claude/plugins/**)' \
    'permissions.md uses Read(~/.claude/plugins/**) — covers cache/ and marketplaces/'
assert_contains "$PERMS" '`${CLAUDE_PLUGIN_ROOT}` is **not** expanded inside `permissions.allow`' \
    'permissions.md notes CLAUDE_PLUGIN_ROOT does not expand in allow entries'

# --- 3. Repo read entry uses double-slash absolute form. -----------------
assert_contains "$PERMS" 'Read(//<repo-path>/**)' \
    'permissions.md uses Read(//<repo-path>/**) template'
assert_contains "$PERMS" '`//` prefix is the Claude Code grammar for **filesystem-absolute**' \
    'permissions.md explains the double-slash convention'
assert_contains "$PERMS" 'Read(//Users/me/Work/AuthService/**)' \
    'permissions.md shows a concrete double-slash example'

# --- 4. Idempotency contract. --------------------------------------------
assert_contains "$PERMS" '### 3. Idempotency and refresh' \
    'permissions.md has an idempotency / refresh subsection'
assert_contains "$PERMS" 'auto-add path is **idempotent**' \
    'permissions.md states the auto-add path is idempotent'
assert_contains "$PERMS" '`--refresh-permissions` re-runs both Step 3c.1 (Bash, interactive) and Step 3c.2 (Read, automatic)' \
    'permissions.md states refresh covers both flows'

# --- 5. Justification subsection: why no prompt for Read. ----------------
assert_contains "$PERMS" '### 4. Why not prompt for Read approvals?' \
    'permissions.md justifies the no-prompt decision'
assert_contains "$PERMS" 'background agents can'"'"'t respond, foreground agents stall the loop' \
    'permissions.md cites background-agent-cannot-prompt as a reason'

# --- 6. SKILL.md Step 3c description names both flows. -------------------
assert_contains "$SKILL" 'auto-add Read pre-approvals for the harness plugin files' \
    'SKILL.md Step 3c summary names the plugin Read auto-add'
assert_contains "$SKILL" '`Read(~/.claude/plugins/**)`' \
    'SKILL.md Step 3c summary includes the plugin Read entry verbatim'
assert_contains "$SKILL" '`Read(//<repo-path>/**)`' \
    'SKILL.md Step 3c summary includes the repo Read entry template'

# --- 7. SKILL.md Reference Documents table covers both flows. ------------
assert_contains "$SKILL" 'Bash permissions proposal + Read pre-approvals (Step 3c)' \
    'SKILL.md Reference Documents row covers both flows'

# --- 8. SKILL.md post-init summary mentions plugin + repo Read entries. --
assert_contains "$SKILL" 'plugin-read entry (`Read(~/.claude/plugins/**)`)' \
    'SKILL.md final summary names the plugin Read entry'
assert_contains "$SKILL" 'M repo-read entries' \
    'SKILL.md final summary names the per-repo Read entries'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

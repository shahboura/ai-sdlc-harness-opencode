#!/usr/bin/env bash
# F8 regression: cross-repo contracts live in a dedicated per-workflow
# artifact `ai/<YYYY-MM-DD>-<id>/contracts.md`, not inline in plan.md.
#
# Pre-Option-B, contracts were defined inside plan.md Section 2b. The
# orchestrator extracted them by Markdown header scan, the reviewer had
# no compliance schema, and amendments produced noisy plan.md diffs.
#
# Locks the cross-file contract:
#   workflow-paths.md:           declares contracts.md as a P2 plan-generator
#                                output and adds it to the Consumers table.
#   plan-generator/SKILL.md:     Section 2b writes contracts.md (not inline),
#                                with the canonical heading format
#                                `## C<n> — <type>` and the Producer / Consumer /
#                                Definition field schema.
#   develop.md:                  Cross-Repo Contracts section names contracts.md
#                                as the canonical source; CONTRACTS_CTX is the
#                                injection mechanism.
#   prompt-templates.md:         CONTRACTS_CTX reads contracts.md.
#   reviewer/index.md:           Phase A step 3a reads contracts.md; step 4 has
#                                the contract-compliance check with `Contract: C<n>`
#                                annotation in [S<n>] comments.
#   migrate.md:                  Per-story sub-step 6 extracts inline contracts
#                                from in-flight stories; closed stories untouched.
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
assert_not_contains() {
    local file="$1" needle="$2" label="$3"
    if grep -qF -- "$needle" "$file"; then _fail "$label" "must not contain: $needle"; else _pass "$label"; fi
}

PATHS="$REPO_ROOT/skills/dev-workflow/context/workflow-paths.md"
PLAN_GEN="$REPO_ROOT/skills/plan-generator/SKILL.md"
DEVELOP="$REPO_ROOT/skills/dev-workflow/commands/develop.md"
TEMPLATES="$REPO_ROOT/skills/dev-workflow/context/prompt-templates.md"
REVIEWER="$REPO_ROOT/agents/reviewer/index.md"
MIGRATE="$REPO_ROOT/skills/dev-workflow/commands/migrate.md"

# --- 1. workflow-paths.md registers contracts.md. ------------------------
assert_contains "$PATHS" 'contracts.md' \
    'workflow-paths.md lists contracts.md in the canonical layout'
assert_contains "$PATHS" 'P2  — plan-generator output (multi-repo only; absent on single-repo stories)' \
    'workflow-paths.md notes contracts.md is multi-repo only'
assert_contains "$PATHS" '`contracts.md` (multi-repo only)' \
    'workflow-paths.md Consumers table updates P2 row with contracts.md'

# --- 2. plan-generator Section 2b writes contracts.md. -------------------
assert_contains "$PLAN_GEN" 'contracts live at `ai/<YYYY-MM-DD>-<work-item-id>/contracts.md`' \
    'plan-generator declares the canonical contracts.md path'
assert_contains "$PLAN_GEN" 'write a dedicated `contracts.md`' \
    'plan-generator instructs writing a dedicated contracts.md'
assert_contains "$PLAN_GEN" '## Cross-Repo Contracts → see contracts.md' \
    'plan-generator declares the plan.md stub format'
assert_contains "$PLAN_GEN" '## C1 — HTTP API' \
    'plan-generator shows the canonical contracts.md heading format'
# Reviewer compliance hook surface is mentioned.
assert_contains "$PLAN_GEN" '`Contract: C<n>` annotation' \
    'plan-generator names the reviewer'"'"'s Contract: C<n> annotation format'

# --- 3. develop.md reads contracts.md (not plan.md Contracts section). --
assert_contains "$DEVELOP" 'reads `contracts.md` (if it exists' \
    'develop.md reads contracts.md rather than plan section'
assert_contains "$DEVELOP" 'CONTRACTS_CTX is omitted entirely' \
    'develop.md notes single-repo behaviour (CONTRACTS_CTX omitted)'
assert_not_contains "$DEVELOP" "reads the plan's Contracts section" \
    'develop.md no longer says "reads the plan'"'"'s Contracts section"'

# --- 4. CONTRACTS_CTX template references contracts.md. ------------------
assert_contains "$TEMPLATES" '`ai/<workflow-dir>/contracts.md` exists AND at least one `## C<n>` section in it names this repo' \
    'CONTRACTS_CTX gating reads contracts.md'
assert_contains "$TEMPLATES" 'from ai/<workflow-dir>/contracts.md' \
    'CONTRACTS_CTX block header points at contracts.md'

# --- 5. Reviewer reads contracts.md in Phase A. --------------------------
assert_contains "$REVIEWER" '3a. **Read `ai/<workflow-dir>/contracts.md` if it exists**' \
    'reviewer Phase A has the contracts.md read step (3a)'
assert_contains "$REVIEWER" '**Cross-repo contract compliance** (when contracts.md exists)' \
    'reviewer step 4 has the contract-compliance bullet'
assert_contains "$REVIEWER" 'Contract: C1 — request DTO is missing' \
    'reviewer documents the [S<n>] Contract: C<n> annotation format with example'

# --- 6. Migrate has the extraction sub-step for in-flight stories. -------
assert_contains "$MIGRATE" 'Cross-repo contracts extraction (in-flight stories only)' \
    'migrate.md has the contracts extraction sub-step'
assert_contains "$MIGRATE" 'For **closed stories** (Story-State `Archived` / `Done` / `Aborted`), do NOT extract' \
    'migrate.md leaves closed-story plans untouched'
assert_contains "$MIGRATE" 'Moved to `contracts.md` during v1.x → v2.0 migration' \
    'migrate.md replaces the plan section with a stub pointing at contracts.md'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

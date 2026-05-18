#!/usr/bin/env bash
# Doc-grep regression coverage for the ad-hoc request handling flow added in
# the `Unreleased` section of CHANGELOG. Locks the cross-file contract:
#
#   GATE #2 / GATE #3 prompts expose REQUEST option   →
#   handle-request.md triages via Reviewer (mode: request-triage)   →
#   GATE #5 confirms in-scope items                   →
#   plan-generator (MODE: ad-hoc-tasks) appends rows under `## Ad-hoc Tasks (Batch N)`   →
#   develop.md re-enters scoped to those rows.
#
# Every link in that chain must be present in the relevant file. If a future
# refactor breaks one of them, this suite fails fast.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

assert_contains() {
    local file="$1" needle="$2" label="$3"
    if grep -qF -- "$needle" "$file"; then _pass "$label"; else _fail "$label" "expected to find: $needle"; fi
}
assert_regex() {
    local file="$1" pattern="$2" label="$3"
    if grep -qE -- "$pattern" "$file"; then _pass "$label"; else _fail "$label" "expected to match regex: $pattern"; fi
}
assert_not_contains() {
    local file="$1" needle="$2" label="$3"
    if grep -qF -- "$needle" "$file"; then _fail "$label" "must not contain: $needle"; else _pass "$label"; fi
}

HANDLE="$REPO_ROOT/skills/dev-workflow/commands/handle-request.md"
TRIAGE="$REPO_ROOT/agents/reviewer/request-triage.md"
REVIEWER_IDX="$REPO_ROOT/agents/reviewer/index.md"
APPROVE_IMPL="$REPO_ROOT/skills/dev-workflow/commands/approve-impl.md"
CREATE_PR="$REPO_ROOT/skills/dev-workflow/commands/create-pr.md"
PLAN_GEN="$REPO_ROOT/skills/plan-generator/SKILL.md"
ORCH_RULES="$REPO_ROOT/skills/dev-workflow/context/orchestrator-rules.md"
DEV_WORKFLOW_SKILL="$REPO_ROOT/skills/dev-workflow/SKILL.md"
SCHEMA="$REPO_ROOT/agents/shared/status-schema.md"
WORKFLOW_STATUS="$REPO_ROOT/skills/workflow-status/SKILL.md"
GETTING_STARTED="$REPO_ROOT/getting-started.md"

# --- 0. The new files exist and are non-trivial. --------------------------
for f in "$HANDLE" "$TRIAGE"; do
    if [ -f "$f" ] && [ "$(wc -l < "$f")" -ge 30 ]; then
        _pass "$(basename "$f") exists and is non-trivial"
    else
        _fail "$(basename "$f") exists and is non-trivial" "missing or too short: $f"
    fi
done

# --- 1. handle-request.md declares the canonical 8-step flow. -------------
assert_contains "$HANDLE" '### Step 1 — Capture and Number Requests' 'handle-request Step 1 captures and numbers requests'
assert_contains "$HANDLE" '### Step 2 — Reviewer: Triage Each Request' 'handle-request Step 2 delegates triage to the reviewer'
assert_contains "$HANDLE" 'MODE: request-triage' 'handle-request invokes the reviewer with MODE: request-triage'
assert_contains "$HANDLE" '### Step 4 — Present Triage Report (HUMAN GATE #5)' 'handle-request presents the report at GATE #5'
assert_contains "$HANDLE" '### Step 6 — Planner: Append Ad-Hoc Tasks to Tracker' 'handle-request Step 6 delegates task creation to the planner'
assert_contains "$HANDLE" 'MODE: ad-hoc-tasks' 'handle-request invokes the planner with MODE: ad-hoc-tasks'
assert_contains "$HANDLE" '### Step 7 — Re-Enter TDD Development Loop' 'handle-request Step 7 re-enters the dev loop'
assert_contains "$HANDLE" 'commands/develop.md' 'handle-request Step 7 hands off to develop.md'
assert_contains "$HANDLE" '### Step 8 — Return to the Previous Gate' 'handle-request Step 8 resumes the gate that was interrupted'

# Provenance contract — the `[AHR-<n>]` ID, the `ad-hoc: [AHR-<n>]` Notes
# token, and the three submission sources are non-negotiable. The orchestrator
# rules and the plan-generator both depend on these tokens.
assert_contains "$HANDLE" '[AHR-<n>]' 'handle-request uses the canonical [AHR-<n>] request ID'
assert_contains "$HANDLE" 'ad-hoc: [AHR-<n>]' 'handle-request specifies the canonical Notes provenance token'
assert_regex "$HANDLE" 'gate-2.*gate-3.*mid-phase' 'handle-request enumerates the three submission sources (gate-2, gate-3, mid-phase)'

# Confirm-before-action contract — even in-scope items go through the GATE.
assert_contains "$HANDLE" '[1] Confirm' 'handle-request requires human confirmation even for in-scope items'

# Per-row decision matrix — every (repo, AHR) pair gets its own row so a single
# request classified differently across repos can be answered cleanly.
assert_contains "$HANDLE" 'per-decision matrix' 'handle-request uses a per-decision matrix at Gate #5'
assert_contains "$HANDLE" 'One row per repo×AHR pair' 'handle-request matrix has one row per repo×AHR pair'
assert_contains "$HANDLE" 'A single `[AHR-<n>]` classified differently across repos' 'handle-request documents the cross-repo-mix case'

# Out-of-scope branch must surface explicit options, never auto-merge.
assert_contains "$HANDLE" '[a] Expand scope' 'handle-request offers the Expand-scope branch for out-of-scope requests'
assert_contains "$HANDLE" '[b] Defer as new story' 'handle-request offers the Defer-as-new-story branch'
assert_contains "$HANDLE" '[c] Withdraw' 'handle-request offers the Withdraw branch'
assert_contains "$HANDLE" 'MODE: plan-amendment' 'handle-request points Expand-scope at the plan-amendment mode'

# UNCLASSIFIED handling (TRIAGE_PARTIAL) — never falls through silently.
assert_contains "$HANDLE" 'Classification: UNCLASSIFIED' 'handle-request surfaces UNCLASSIFIED rows in the matrix'
assert_contains "$HANDLE" '[f] Re-triage with hint' 'handle-request offers Re-triage with hint for UNCLASSIFIED'
assert_contains "$HANDLE" '`TRIAGE_PARTIAL` never falls through' 'handle-request documents that TRIAGE_PARTIAL has a handler'

# Special verdict: PLAN_NOT_FOUND escalates, never improvises.
assert_contains "$HANDLE" '#### Special verdict: PLAN_NOT_FOUND' 'handle-request declares the PLAN_NOT_FOUND failure mode'
assert_contains "$HANDLE" 'MUST NOT fabricate a plan path' 'handle-request forbids fabricating a plan path on PLAN_NOT_FOUND'

# Global escape valve.
assert_contains "$HANDLE" '[SKIP-ALL]' 'handle-request offers a [SKIP-ALL] global escape'

# Plan snapshot/restore — workspace-agnostic rollback.
# NOTE: the snapshot lifecycle is locked in two places: this block covers the
# round-2 "rollback path exists" contract; the round-3 block at line ~270
# adds on-disk durability. Don't add a third presence-of-snapshot assertion
# without deleting one of these — they're load-bearing in pairs.
assert_contains "$HANDLE" 'workspace-agnostic' 'handle-request notes the snapshot works for both git-repo and plain-directory workspaces'
assert_contains "$HANDLE" 'Prefer the in-memory `PLAN_SNAPSHOT` cache' 'handle-request restores from snapshot on amendment rejection (cache-first)'
assert_contains "$HANDLE" 'Read the on-disk snapshot' 'handle-request falls back to the on-disk snapshot when cache is evicted'

# Synchronous mid-phase handling — no queue, no checkpoint.
# NOTE: these are doc-drift catchers, not behavioural tests. They verify the
# documentation still uses the canonical wording for the synchronous-no-queue
# contract; they do NOT verify that any agent or orchestrator actually behaves
# synchronously. If a future edit replaces these phrases with synonyms, the
# tests fail and force a deliberate review — but the underlying behaviour is
# enforced by the orchestrator's single-loop nature, not by this suite.
assert_contains "$HANDLE" 'synchronously and in-line' 'handle-request handles mid-phase requests synchronously (drift catcher)'
assert_contains "$HANDLE" 'no orchestrator-side queue' 'handle-request eliminates the queue design (drift catcher)'
assert_contains "$HANDLE" 'Scheduling semantics (Non-Negotiable)' 'handle-request pins the no-preemption no-priority scheduling contract (drift catcher)'

# Tracker section headings — must match the planner's row-template header.
assert_contains "$HANDLE" '## Ad-hoc Tasks (Batch <N>)' 'handle-request names the Ad-hoc Tasks heading'
assert_contains "$HANDLE" '## Deferred Requests' 'handle-request names the Deferred Requests section'

# --- 2. request-triage.md declares the four classification verdicts. -----
assert_contains "$TRIAGE" 'IN_SCOPE_BUG' 'request-triage declares IN_SCOPE_BUG'
assert_contains "$TRIAGE" 'IN_SCOPE_AC_MISS' 'request-triage declares IN_SCOPE_AC_MISS'
assert_contains "$TRIAGE" 'OUT_OF_SCOPE' 'request-triage declares OUT_OF_SCOPE'
assert_contains "$TRIAGE" 'PLAN_CONFLICT' 'request-triage declares PLAN_CONFLICT'
assert_contains "$TRIAGE" 'DUPLICATE' 'request-triage declares DUPLICATE'
assert_contains "$TRIAGE" 'INVALID' 'request-triage declares INVALID'

# Verdict enum — the orchestrator routing matrix keys off these.
assert_contains "$TRIAGE" 'TRIAGE_COMPLETE' 'request-triage declares Verdict TRIAGE_COMPLETE'
assert_contains "$TRIAGE" 'TRIAGE_PARTIAL' 'request-triage declares Verdict TRIAGE_PARTIAL'
assert_contains "$TRIAGE" 'PLAN_NOT_FOUND' 'request-triage declares Verdict PLAN_NOT_FOUND (setup-error path)'

# Strict-analytical contract — no code, no tracker writes.
assert_contains "$TRIAGE" 'NOT write or edit any file' 'request-triage forbids file writes'
assert_contains "$TRIAGE" 'do NOT decide what happens to out-of-scope' 'request-triage defers out-of-scope dispositions to the human'

# AGENT STATUS block follows the schema.
assert_contains "$TRIAGE" '📋 AGENT STATUS' 'request-triage declares an AGENT STATUS block'
assert_regex "$TRIAGE" '^- Mode: request-triage' 'request-triage AGENT STATUS sets Mode: request-triage'
assert_regex "$TRIAGE" '^- Verdict:' 'request-triage AGENT STATUS declares Verdict'

# --- 3. Reviewer index.md registers the new mode. -------------------------
assert_contains "$REVIEWER_IDX" 'agents/reviewer/request-triage.md' 'reviewer/index.md references request-triage.md'
assert_contains "$REVIEWER_IDX" 'mode: request-triage' 'reviewer/index.md names the request-triage mode'

# --- 4. Gate prompts expose the REQUEST option. ---------------------------
# GATE #2 in approve-impl.md.
assert_contains "$APPROVE_IMPL" 'REQUEST <description>' 'approve-impl GATE #2 prompt declares REQUEST <description>'
assert_contains "$APPROVE_IMPL" 'commands/handle-request.md' 'approve-impl routes REQUEST option to handle-request.md'
assert_contains "$APPROVE_IMPL" 'Source: gate-2' 'approve-impl passes Source: gate-2 to handle-request'

# GATE #3 in create-pr.md.
assert_contains "$CREATE_PR" 'REQUEST <description>' 'create-pr GATE #3 prompt declares REQUEST <description>'
assert_contains "$CREATE_PR" 'commands/handle-request.md' 'create-pr routes REQUEST option to handle-request.md'
assert_contains "$CREATE_PR" 'Source: gate-3' 'create-pr passes Source: gate-3 to handle-request'
# After the batch, GATE #3 re-runs the pre-PR review.
assert_contains "$CREATE_PR" 're-run Step 2 (Pre-PR Holistic Review)' 'create-pr re-runs pre-PR review after ad-hoc batch'

# --- 5. plan-generator declares MODE: ad-hoc-tasks and MODE: plan-amendment. -
assert_contains "$PLAN_GEN" '## Ad-Hoc Task Mode (`MODE: ad-hoc-tasks`)' 'plan-generator declares Ad-Hoc Task Mode'
assert_contains "$PLAN_GEN" '## Plan Amendment Mode (`MODE: plan-amendment`)' 'plan-generator declares Plan Amendment Mode'
assert_contains "$PLAN_GEN" '## Ad-hoc Tasks (Batch <N>)' 'plan-generator ad-hoc-tasks names the canonical batch heading'
assert_contains "$PLAN_GEN" 'ad-hoc: [AHR-<n>]' 'plan-generator ad-hoc-tasks Notes column carries the provenance token'
assert_contains "$PLAN_GEN" 'do NOT reorder, edit, or remove any' 'plan-generator ad-hoc-tasks forbids mutating existing rows'
assert_contains "$PLAN_GEN" 'tracker-transition-guard' 'plan-generator ad-hoc-tasks references the transition guard'
assert_contains "$PLAN_GEN" 'Ad-hoc requests started' 'plan-generator ad-hoc-tasks adds the Ad-hoc requests started metric'
assert_contains "$PLAN_GEN" 'Ad-hoc requests completed' 'plan-generator ad-hoc-tasks adds the Ad-hoc requests completed metric'

# Plan-amendment mode lives in its own section and writes a new plan section
# only — it does NOT touch the tracker.
assert_contains "$PLAN_GEN" '## Plan Amendment — Ad-Hoc Round <N>' 'plan-amendment names the canonical amendment heading'
assert_contains "$PLAN_GEN" 'Do NOT touch the tracker in this mode' 'plan-amendment forbids tracker writes'

# --- 6. Orchestrator rules carry the Ad-Hoc Request Handling section. ----
assert_contains "$ORCH_RULES" '## Ad-Hoc Request Handling' 'orchestrator-rules declares the Ad-Hoc Request Handling section'
assert_contains "$ORCH_RULES" 'GATE #5' 'orchestrator-rules names GATE #5'
assert_contains "$ORCH_RULES" 'No code work without triage' 'orchestrator-rules forbids code work before triage'
assert_contains "$ORCH_RULES" 'Out-of-scope items are never silently merged' 'orchestrator-rules forbids silent out-of-scope merges'
assert_contains "$ORCH_RULES" 'Background agents are not preempted, killed, or paused' 'orchestrator-rules forbids preemption of in-flight agents'

# Constraint #2 mentions GATE #5 so the gate count stays in sync.
assert_regex "$ORCH_RULES" 'Four mandatory human gates plus an inter-gate ad-hoc gate' 'orchestrator-rules constraint #2 mentions the inter-gate GATE #5'

# Synchronous mid-phase handling — explicit "no queue" pinning. These are
# also doc-drift catchers; see the note above the matching block in handle-
# request.md for rationale.
assert_contains "$ORCH_RULES" 'Synchronous, Non-Negotiable' 'orchestrator-rules pins the synchronous handling contract (drift catcher)'
assert_contains "$ORCH_RULES" 'there is no orchestrator-side queue' 'orchestrator-rules eliminates the queue concept (drift catcher)'
assert_contains "$ORCH_RULES" 'no "drain at the next safe checkpoint" hook' 'orchestrator-rules eliminates the checkpoint-drain concept (drift catcher)'

# Failure-Mode Pinning section enumerates the three documented failure paths.
assert_contains "$ORCH_RULES" '### Failure-Mode Pinning' 'orchestrator-rules declares the Failure-Mode Pinning section'
assert_contains "$ORCH_RULES" '`Verdict: PLAN_NOT_FOUND`' 'orchestrator-rules pins the PLAN_NOT_FOUND failure mode'
assert_contains "$ORCH_RULES" '`Verdict: TRIAGE_PARTIAL`' 'orchestrator-rules pins the TRIAGE_PARTIAL failure mode'
assert_contains "$ORCH_RULES" 'Plan-amendment rejection at the scoped GATE #1' 'orchestrator-rules pins the amendment-rejection rollback'
assert_contains "$ORCH_RULES" 'Do NOT fabricate a plan path' 'orchestrator-rules forbids fabricated plan paths'

# Repo-Scope Inference Bounds — bounded substring-matching only, no NLP.
assert_contains "$ORCH_RULES" '### Repo-Scope Inference Bounds' 'orchestrator-rules declares Repo-Scope Inference Bounds'
assert_contains "$ORCH_RULES" 'substring-matching' 'orchestrator-rules permits substring-matching for repo scope'
assert_contains "$ORCH_RULES" 'MUST NOT' 'orchestrator-rules declares prohibitions for repo-scope inference'

# Deferred Requests ownership — now orchestrator, not Planner (changed in the
# round-2 review). Pin the change.
assert_contains "$ORCH_RULES" 'is owned by the **orchestrator**' 'orchestrator-rules pins Deferred Requests ownership to the orchestrator'

# --- 7. dev-workflow SKILL.md registers the `request` command. ------------
assert_contains "$DEV_WORKFLOW_SKILL" '| `request` |' 'dev-workflow SKILL.md commands table lists `request`'
assert_contains "$DEV_WORKFLOW_SKILL" 'commands/handle-request.md' 'dev-workflow SKILL.md points `request` at handle-request.md'
assert_contains "$DEV_WORKFLOW_SKILL" '/dev-workflow request' 'dev-workflow SKILL.md documents the /dev-workflow request invocation'

# --- 8. Status-schema lists the request-triage mode. ---------------------
assert_contains "$SCHEMA" 'request-triage' 'status-schema declares the request-triage reviewer mode'
assert_contains "$SCHEMA" 'TRIAGE_COMPLETE' 'status-schema lists TRIAGE_COMPLETE in the Verdict enum'
assert_contains "$SCHEMA" 'Requests triaged' 'status-schema declares the Requests triaged field'

# --- 9. handle-request points back at the new reviewer mode by file path. -
# Drift catcher — if someone renames `agents/reviewer/request-triage.md`, the
# orchestrator prompt template inside handle-request.md becomes a dangling
# reference. Lock the path.
assert_contains "$HANDLE" 'agents/reviewer/request-triage.md' 'handle-request points the reviewer at request-triage.md by file path'

# --- 10. CHANGELOG carries an [Unreleased] section that describes the flow. -
CHANGELOG="$REPO_ROOT/CHANGELOG.md"
assert_contains "$CHANGELOG" '## [2.0.0]' 'CHANGELOG declares the 2.0.0 release section'
# The unreleased entry must describe the user-visible behaviour, not internals.
# Per the user-memory rule, no work-stream / slice IDs. Anchor on the flow noun.
assert_contains "$CHANGELOG" 'Ad-hoc requests between approval gates' 'CHANGELOG 2.0.0 describes the ad-hoc request flow'

# --- 11. workflow-status is section-aware (was a major review finding). ---
assert_contains "$WORKFLOW_STATUS" 'Section-Aware' 'workflow-status declares section-aware reading'
assert_contains "$WORKFLOW_STATUS" '## Ad-hoc Tasks (Batch <N>)' 'workflow-status names the Ad-hoc Tasks section'
assert_contains "$WORKFLOW_STATUS" '## Amendments (PR Review Round <N>)' 'workflow-status names the Amendments section'
assert_contains "$WORKFLOW_STATUS" '## Deferred Requests' 'workflow-status names the Deferred Requests section'
assert_contains "$WORKFLOW_STATUS" 'Inter-gate: Ad-Hoc Request Handling' 'workflow-status phase-detection includes the inter-gate phase'
assert_contains "$WORKFLOW_STATUS" 'Any Amendment row' 'workflow-status detects Phase 7 from Amendment row states'
# Dashboard renders sections as separate groups, not lumped together.
assert_contains "$WORKFLOW_STATUS" '▸ Main' 'workflow-status dashboard renders Main as a separate group'
assert_contains "$WORKFLOW_STATUS" '▸ Ad-hoc Tasks (Batch 1)' 'workflow-status dashboard renders Ad-hoc Tasks as a separate group'

# --- 12. plan-generator declares the orchestrator-owned snapshot/restore. -
assert_contains "$PLAN_GEN" 'PLAN_SNAPSHOT' 'plan-amendment references the orchestrator-owned PLAN_SNAPSHOT'
assert_contains "$PLAN_GEN" 'Rollback is owned by the orchestrator' 'plan-amendment delegates rollback to the orchestrator'
assert_contains "$PLAN_GEN" 'workspace-agnostic' 'plan-amendment notes the snapshot works for both workspace shapes'

# --- 13. getting-started has the worked-example gaps the advisor flagged. -
assert_contains "$GETTING_STARTED" 'snapshots the plan file' 'getting-started documents the plan snapshot'
assert_contains "$GETTING_STARTED" 'how to back out' 'getting-started covers the reject-amendment recovery path'
assert_contains "$GETTING_STARTED" 'next idle cycle' 'getting-started documents the mid-phase scheduling semantics'
assert_contains "$GETTING_STARTED" 'do *not* jump the queue' 'getting-started clarifies mid-phase requests do not preempt'
assert_contains "$GETTING_STARTED" 'IN_SCOPE_BUG' 'getting-started shows the cross-repo classification mix example'
assert_contains "$GETTING_STARTED" '/workflow-status' 'getting-started points users at /workflow-status'

# --- 14. Round 3 critical fix C1 — concurrency model precision. -----------
assert_contains "$HANDLE" 'Concurrency model' 'handle-request explains the concurrency model (round 3 C1 fix)'
assert_contains "$HANDLE" 'cannot service their completion notifications' 'handle-request acknowledges deferred notification servicing'
assert_contains "$ORCH_RULES" 'cannot *service*' 'orchestrator-rules acknowledges deferred notification servicing'

# --- 15. Round 3 critical fix C2 — row-action ordering and re-render bound. -
assert_contains "$HANDLE" 'Row-action execution order' 'handle-request pins row-action execution order'
assert_contains "$HANDLE" 'All `[a] Expand scope` rows first' 'handle-request runs [a] rows before [f] rows'
assert_contains "$HANDLE" 'Matrix re-render bound' 'handle-request bounds the matrix re-render count'
assert_contains "$HANDLE" 'at most 3 times per' 'handle-request caps re-renders at 3 per [AHR-<n>]'
assert_contains "$HANDLE" 're_render_count' 'handle-request names the per-AHR re-render counter'

# --- 16. Round 3 major fix M1 — on-disk snapshot durability. --------------
assert_contains "$HANDLE" 'Snapshot the plan to disk' 'handle-request snapshots the plan to disk (round 3 M1 fix)'
assert_contains "$HANDLE" 'ai/.snapshots/' 'handle-request names the canonical snapshot directory'
assert_contains "$HANDLE" 'survives session crashes' 'handle-request notes the on-disk snapshot is crash-durable'
assert_contains "$HANDLE" 'Delete the on-disk snapshot' 'handle-request cleans up the snapshot on approval'
assert_contains "$PLAN_GEN" '.snapshots/' 'plan-amendment references the on-disk snapshot location'
assert_contains "$PLAN_GEN" 'stop-failure-recovery.sh' 'plan-amendment cross-references the recovery hook'
# Hook script knows about snapshots — the stop-failure-recovery extends the
# existing API-error recovery block with snapshot detection.
RECOVERY_SCRIPT="$REPO_ROOT/scripts/stop-failure-recovery.sh"
assert_contains "$RECOVERY_SCRIPT" 'SNAPSHOT_DIR' 'stop-failure-recovery scans the snapshot directory'
assert_contains "$RECOVERY_SCRIPT" 'orphan plan snapshot' 'stop-failure-recovery names orphan snapshots in the prompt'

# --- 17. Round 3 major fix M2 — [h] override class routing. ---------------
assert_contains "$HANDLE" 'Override-class routing' 'handle-request specifies override-class routing'
# Anchor the regex on the literal `[h]` token in the override-class table so the
# assertion fails if the [h] → OUT_OF_SCOPE / PLAN_CONFLICT routing rows are
# deleted. A loose pattern would survive deletion of just the routing while
# OUT_OF_SCOPE still appeared elsewhere in the file.
assert_regex "$HANDLE" '\[h\].*OUT_OF_SCOPE' 'handle-request documents [h] override to OUT_OF_SCOPE'
assert_regex "$HANDLE" '\[h\].*PLAN_CONFLICT' 'handle-request documents [h] override to PLAN_CONFLICT'
assert_contains "$HANDLE" 'Matrix re-renders for this row only' 'handle-request triggers per-row re-render on out-of-scope override'

# --- 18. Round 3 major fix M3 — multi-valued phase detection. -------------
assert_contains "$WORKFLOW_STATUS" 'multi-valued by construction' 'workflow-status detects phase as multi-valued (round 3 M3 fix)'
assert_contains "$WORKFLOW_STATUS" 'joining them with ` + `' 'workflow-status joins multiple phases with " + "'
assert_contains "$WORKFLOW_STATUS" 'Phase 5: Testing + Inter-gate' 'workflow-status example shows multi-valued phase output'

# --- 19. Round 3 major fix M4 — ambiguous-match disambiguation. -----------
assert_contains "$ORCH_RULES" 'Ambiguous match' 'orchestrator-rules declares the Ambiguous match state'
assert_contains "$ORCH_RULES" 'Repo Disambiguation' 'orchestrator-rules names the disambiguation prompt'
assert_contains "$ORCH_RULES" 'disambiguated-from:' 'orchestrator-rules records disambiguation provenance in Notes'

# --- 20. Round 3 suggestion S1 — Tracker Schema Reference page. -----------
SCHEMA_REF="$REPO_ROOT/skills/plan-generator/tracker-schema.md"
if [ -f "$SCHEMA_REF" ] && [ "$(wc -l < "$SCHEMA_REF")" -ge 100 ]; then
    _pass 'tracker-schema.md exists and is non-trivial'
else
    _fail 'tracker-schema.md exists and is non-trivial' "missing or too short: $SCHEMA_REF"
fi
assert_contains "$SCHEMA_REF" '# Tracker Schema Reference' 'tracker-schema declares itself as the schema reference'
assert_contains "$SCHEMA_REF" '## Sections' 'tracker-schema enumerates section types'
assert_contains "$SCHEMA_REF" '## Notes column tokens' 'tracker-schema enumerates Notes-column tokens'
assert_contains "$SCHEMA_REF" '## Deferred Requests table' 'tracker-schema covers the Deferred Requests table'
# Token vocabulary anchored in one place.
assert_contains "$SCHEMA_REF" '`test-required:' 'tracker-schema lists test-required'
assert_contains "$SCHEMA_REF" '`depends:' 'tracker-schema lists depends'
assert_contains "$SCHEMA_REF" '`PR-comment:' 'tracker-schema lists PR-comment'
assert_contains "$SCHEMA_REF" '`ad-hoc:' 'tracker-schema lists ad-hoc'
assert_contains "$SCHEMA_REF" '`[API:' 'tracker-schema lists the API annotation'
# Cross-referenced by the surfaces that touch the schema.
assert_contains "$PLAN_GEN" 'tracker-schema.md' 'plan-generator links to tracker-schema.md'
assert_contains "$HANDLE" 'tracker-schema.md' 'handle-request links to tracker-schema.md'

# --- 21. Round 3 suggestion S2 — Step 8 re-scans lane state. --------------
assert_contains "$HANDLE" 're-scan lane state, do not assume' 'handle-request Step 8 re-scans lane state on mid-phase resume'
assert_contains "$HANDLE" 'Process any deferred completion notifications first' 'handle-request Step 8 drains deferred completions first'

# --- 22. Round 4 fix M-1 — durable re_render_count via Pending Requests. --
assert_contains "$HANDLE" '## Pending Requests' 'handle-request declares the Pending Requests ledger'
assert_contains "$HANDLE" 'durable across session interruptions' 'handle-request notes the re-render counter is durable'
assert_contains "$HANDLE" 'next session reads `## Pending Requests`' 'handle-request specifies recovery from the ledger row'
assert_contains "$HANDLE" 'Re-renders' 'handle-request names the Re-renders column'
# Step 1 writes the ledger row immediately.
assert_contains "$HANDLE" 'Write a `## Pending Requests` ledger row' 'handle-request Step 1 writes the ledger row'

# --- 23. Round 4 fix M-2 — worked example for re-render counter ticks. ----
assert_contains "$HANDLE" 'Worked example' 'handle-request has a worked-example for the re-render counter'
assert_contains "$HANDLE" 'Increment rules' 'handle-request enumerates the re-render increment rules'
# Every increment trigger is named in the table.
assert_contains "$HANDLE" '`[a] Expand scope` rejected' 'handle-request increment table covers [a] rejection'
assert_contains "$HANDLE" '`[a] Expand scope` approved' 'handle-request increment table covers [a] approval (re-triage)'

# --- 24. Round 4 fix M-3 — Ad-hoc requests completed phrasing. ------------
# The contradictory "cumulative — overwritten each batch" phrasing is replaced
# with explicit "overwritten by each subsequent batch. Not cumulative".
assert_contains "$SCHEMA_REF" 'overwritten by each subsequent batch' 'tracker-schema fixes the Ad-hoc requests completed phrasing'
assert_contains "$SCHEMA_REF" 'Not cumulative' 'tracker-schema disambiguates the metric is not cumulative'

# --- 25. Round 4 fix M-4 — workflow-status fires on Pending ad-hoc rows. --
# The detector regex must include ⏳ (Pending) in the trigger conditions for
# both Amendments and Ad-hoc Batches, plus a new detector for in-flight
# `## Pending Requests` ledger rows.
assert_contains "$WORKFLOW_STATUS" 'Any Ad-hoc Batch row 🔧, 🔄, or ⏳ (Pending)' 'workflow-status detector fires on Pending ad-hoc rows'
assert_contains "$WORKFLOW_STATUS" 'Any Amendment row 🔧, 🔄, or ⏳ (Pending)' 'workflow-status detector fires on Pending amendment rows'
assert_contains "$WORKFLOW_STATUS" '`## Pending Requests` section exists' 'workflow-status detects in-flight triage from Pending Requests ledger'
assert_contains "$WORKFLOW_STATUS" 'Inter-gate: Ad-Hoc Request Handling (in triage)' 'workflow-status emits in-triage phase string'

# --- 26. Round 4 fix M-5 — disambiguation invalid-input + cascade docs. ---
assert_contains "$ORCH_RULES" 'Could not parse:' 'orchestrator-rules documents the disambiguation invalid-input fallback'
assert_contains "$ORCH_RULES" 'If you pick [3] and any matched repo has no plan slice' 'orchestrator-rules warns about [3] + PLAN_NOT_FOUND cascade'
assert_contains "$ORCH_RULES" 'Why does `[3]` cascade on PLAN_NOT_FOUND' 'orchestrator-rules explains the cascade rationale'

# --- 27. Round 4 fix m-1 — tracker-schema is authoritative for Review Rounds. -
assert_contains "$SCHEMA_REF" '**This file is authoritative**' 'tracker-schema Review Rounds row declares authority'
assert_contains "$ORCH_RULES" 'see `tracker-schema.md` → Task Metrics' 'orchestrator-rules defers Review Rounds semantics to tracker-schema'

# --- 28. Round 4 fix m-2 — [h]→DUPLICATE/INVALID Summary provenance. -----
assert_contains "$HANDLE" 'Summary column provenance' 'handle-request pins the Summary column provenance'
assert_contains "$HANDLE" 'verbatim AHR request text' 'handle-request falls back to verbatim AHR text on UNCLASSIFIED/override'

# --- 29. Round 4 fix S-1 — tracker-schema declares schema authority. ------
assert_contains "$SCHEMA_REF" 'This file is authoritative for the tracker schema' 'tracker-schema declares itself authoritative'
assert_contains "$SCHEMA_REF" 'templates (concrete Markdown' 'tracker-schema delegates row templates to SKILL.md'
# SKILL.md's row-format blocks now defer to the schema page rather than
# carrying their own column definitions verbatim.
assert_contains "$PLAN_GEN" 'authoritative in [`tracker-schema.md`](tracker-schema.md)' 'plan-generator main table defers to tracker-schema for column definitions'
assert_contains "$PLAN_GEN" 'tracker-schema.md#notes-column-tokens' 'plan-generator amendment / ad-hoc blocks cross-reference Notes-token vocabulary'

# --- 30. Round 5 fix C-1 — Worked example self-consistency. ---------------
# The worked example must use ONLY re-rendering actions (the ones listed in
# the Increment rules table). Earlier rounds used `[h] → IN_SCOPE_BUG` which
# is terminal — that contradiction is fixed in round 5.
assert_contains "$HANDLE" '`[a]` again → second amendment rejected' 'worked example uses [a]→rejected for round 2 (a real re-render trigger)'
assert_contains "$HANDLE" 'are **terminal**' 'worked example explicitly lists which choices are terminal'
assert_contains "$HANDLE" 'every other choice is +0' 'worked example pins the +0 default for terminal choices'

# --- 31. Round 5 fix Maj-1 — schema page knows about Pending Requests. ----
assert_contains "$SCHEMA_REF" 'up to **five section types**' 'tracker-schema acknowledges 5 section types after round 5'
assert_contains "$SCHEMA_REF" '## Pending Requests' 'tracker-schema names the Pending Requests section'
assert_contains "$SCHEMA_REF" '## Pending Requests table (Section 2)' 'tracker-schema has a dedicated Pending Requests schema sub-section'
assert_contains "$SCHEMA_REF" 'Re-renders' 'tracker-schema documents the Re-renders column'
assert_contains "$SCHEMA_REF" 'Row lifecycle' 'tracker-schema documents the Pending Requests row lifecycle'
assert_contains "$SCHEMA_REF" 'Order vs disambiguation prompt' 'tracker-schema pins the Step 1 sub-step order'

# --- 32. Round 5 fix Maj-2 — duplicate Notes token dropped. ---------------
# The "re-renders: <n>" Notes token is gone; the Re-renders column is the
# single source of truth.
assert_contains "$HANDLE" 'single source of truth for the counter' 'handle-request pins Re-renders as the single source of truth'
assert_contains "$HANDLE" 'no shadow state, no normalisation contract needed' 'handle-request acknowledges the duplicate-state cleanup'
# Drift catcher — the Notes token format must NOT appear in the row template
# blocks (the canonical writers of the `## Pending Requests` rows). Scoped
# to lines after the first `## Pending Requests` heading and before the
# next `### ` heading so historical/explanatory prose mentioning the dropped
# token (e.g. "previously the Notes column carried `re-renders: <n>`") is
# tolerated and does not produce a false-positive failure.
ledger_template_region=$(awk '
    /^## Pending Requests/ { capture=1 }
    capture && /^### / && !/^### *## Pending Requests/ { exit }
    capture { print }
' "$HANDLE" | head -200)
if printf '%s' "$ledger_template_region" | grep -F 're-renders: <n>' > /dev/null; then
    _fail 'handle-request drops the redundant re-renders: <n> Notes token (row template)' \
          'the dropped token reappeared inside the Pending Requests row template'
else
    _pass 'handle-request drops the redundant re-renders: <n> Notes token (row template)'
fi

# --- 33. Round 5 fix m-1 — ledger-row order pinned, [5] Cancel safe. ------
assert_contains "$HANDLE" 'Order vs the disambiguation prompt' 'handle-request pins the disambiguation-vs-ledger order'
assert_contains "$HANDLE" 'Only write the ledger row **after** scope resolution succeeds' 'handle-request writes the ledger AFTER scope resolution'
assert_contains "$HANDLE" 'return from Step 1 without writing the row' 'handle-request handles [5] Cancel without orphan rows'

# --- 34. Round 5 fix m-2 — snapshot filename includes a uid8 suffix. ------
assert_contains "$HANDLE" '<uid8>.md' 'handle-request snapshot path includes a uid8 suffix'
assert_contains "$HANDLE" 'prevents same-second filename collisions' 'handle-request documents the collision-prevention rationale'
assert_contains "$PLAN_GEN" '<uid8>.md' 'plan-generator references the uid8-suffixed snapshot filename'
# The exact filename the orchestrator wrote must be remembered for deletion
# (otherwise it could delete a concurrent flow's snapshot).
assert_contains "$HANDLE" 'orchestrator must remember the exact filename' 'handle-request pins the per-flow snapshot filename for safe deletion'

# --- 35. B3 — post-Phase-5 ad-hoc batches re-trigger T-TEST hardening. ----
# Without this step, ad-hoc tasks landing at gate-3 or as a post-Phase-5
# mid-phase request ship new production code in the PR without ever being
# checked against the 90% coverage gate.
assert_contains "$HANDLE" '### Step 7b — Re-trigger Phase 5 hardening on affected repos' \
    'handle-request Step 7b re-triggers T-TEST hardening after the ad-hoc batch'
assert_contains "$HANDLE" 'Status: ✅ Done' \
    'Step 7b gates re-trigger on T-TEST being ✅ Done'
assert_contains "$HANDLE" '✅ Done → 🔧 In Progress' \
    'Step 7b names the legal rework transition for T-TEST'
assert_contains "$HANDLE" "commands/test.md" \
    'Step 7b invokes commands/test.md for the re-trigger'
# The no-op-for-gate-2 case must be documented so a reader doesn't assume
# the step always does work.
assert_contains "$HANDLE" 'no-op for `source: gate-2` batches' \
    'Step 7b documents the gate-2 no-op case'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0

# AGENT STATUS Block Schema

> Owner: cross-cutting
> Version: 1.0

<!-- Updated by: dev-workflow-plan.md [M-01] [IMPL-01-12] (sub-steps c, d, e)
     Reason: (c) add owner + version headers per CC-04.4 / CC-04.6;
             (d) reserve Why-no-test allowed-values enumeration (owned by M-20);
             (e) embed CC-02.4.1 machine-readable YAML contract block.
     CC conventions applied: CC-02.4, CC-02.4.1, CC-04.4, CC-04.6 -->

Single source of truth for the `📋 AGENT STATUS` block every subagent emits at the
end of its response. The orchestrator parses these blocks to decide the next
action; the `agent-status-check` hook enforces a structural floor at SubagentStop.

This file is the schema. Each agent's `index.md` (and mode-specific file for
multi-mode agents) declares the example block that the orchestrator will see, and
references this schema so renames stay synchronized.

## Universal floor (every agent, every mode)

Every status block MUST contain:

| Field | Type | Notes |
|-------|------|-------|
| `Agent:` | enum | One of `ai-sdlc-planner`, `ai-sdlc-developer`, `ai-sdlc-tester`, `ai-sdlc-reviewer`. Used by `agent-status-check` for per-agent validation when `agent_type` is missing from the SubagentStop payload. |
| `Phase:` | enum | `1`, `2`, `3`, `4`, `5`, `6`, or `7`. The phase the agent ran under. Phases `3`, `4`, `5`, and `6` are all valid for the reviewer's `request-triage` mode — `3` and `5` for mid-phase `/dev-workflow request` submissions, `4` and `6` for requests submitted at GATE #2 / GATE #3 instead of `APPROVED`. |
| `Story:` | string | The story ID display form (e.g. `#12345`, `PROJ-123`, or a local-markdown filename without extension). |
| `Outcome:` | enum | `SUCCESS \| PARTIAL \| FAILED \| BLOCKED`. Reviewers additionally use `DONE_WITH_CONCERNS` in Phase 3/5. |
| `Next action:` | string | One-line description of what the orchestrator should do next. Non-empty. |

The hook accepts `Verdict:` in place of `Outcome:` for reviewer modes — the
reviewer's verdict carries the routing signal. If both appear, `Verdict:` is
authoritative for routing; `Outcome:` reports execution success.

## Per-agent fields

### Planner — `agents/planner/index.md`

| Field | Required? | Notes |
|-------|-----------|-------|
| `Startup reads:` | ✅ | Comma-separated list of the shared files read at startup per the planner's Startup Protocol (typically `engineering-principles.md, status-schema.md, provider-config.md, language-config.md`). TEST-21 enforces presence in the planner's example block; CC-02.8 declares the read order. |
| `Files written:` | ✅ | List of files saved this invocation, or `none`. |
| `Files failed:` | ✅ | List of files that failed to save, or `none`. |
| `Tracker path:` | ✅ in Phase 2 | Absolute or workspace-relative path to the tracker file. Omitted in Phase 1 where no tracker is produced. |
| `Plan path:` | ✅ in Phase 2 | Path to the plan file. Same Phase 1 rule. |
| `Blockers:` | ✅ | Description, or `none`. |

`Phase:` enum for Planner: `1` (requirements ingestion) or `2` (planning).
Phase 7 amendments re-invoke the Planner with `Phase: 2` (not a new phase) per
`review-response.md` Step 7.

### Developer — `agents/developer/index.md`

| Field | Required? | Notes |
|-------|-----------|-------|
| `Repo:` | ✅ | Repo name from the tracker. |
| `Repo path:` | ✅ | Local repo path provided by the orchestrator. |
| `Language:` | ✅ | Language string from the prompt's LANGUAGE CONTEXT block. |
| `Worktree:` | ✅ | Worktree path from `WORKTREE_CTX`, or `not used (direct branch)` when `worktree_failed: true`. |
| `Worktree branch:` | ✅ | Worktree branch, or `n/a` when `worktree_failed: true`. |
| `Build result:` | ✅ | `PASS (0 warnings) \| FAIL (N errors, M warnings)`. Build-attempt count is reported separately. |
| `Build attempts:` | ✅ | `1 \| 2 \| 3` — caps at 3 per `agents/developer/index.md` Build Failure Recovery. |
| `Commit:` | ✅ | Implementation commit hash, or `none`. |
| `Files changed:` | ✅ | List of modified/created files. |
| `Self-review:` | ✅ | `PASS \| FAIL`. `FAIL` is only valid alongside `Outcome ∈ {PARTIAL, BLOCKED, FAILED}`; the combination `Outcome: SUCCESS` + `Self-review: FAIL` is rejected by the orchestrator (treated as `PARTIAL`). |
| `Concerns:` | ✅ | Free-text description of doubts about correctness, or `none`. Surfaces from `Outcome: DONE_WITH_CONCERNS`. |
| `Blockers:` | ✅ | Description, or `none`. |

`Phase:` for Developer is always `3`. `Outcome:` may be `DONE_WITH_CONCERNS` when
self-review surfaces issues the developer believes are out of scope.

### Tester — `agents/tester/index.md`

`Mode:` is required and disambiguates the two contracts: `auto-tdd` (Phase 3) or
`auto-harden` (Phase 5).

| Field | auto-tdd | auto-harden | Notes |
|-------|----------|-------------|-------|
| `Mode:` | ✅ | ✅ | Required. |
| `Repo:` | ✅ | ✅ | |
| `Repo path:` | ✅ | ✅ | |
| `Language:` | ✅ | ✅ | Language string from the prompt's LANGUAGE CONTEXT block. |
| `Worktree:` | ✅ | ✅ | auto-tdd: worktree path from `WORKTREE_CTX`, or `not used (direct branch)` if `worktree_failed: true`. auto-harden: always `not used (direct branch)` — Phase 5 runs on the feature branch directly, no worktree is created. |
| `Worktree branch:` | ✅ | ✅ | auto-tdd: worktree branch, or `n/a` if `worktree_failed: true`. auto-harden: always `n/a`. |
| `Commit:` | ✅ | ✅ | Canonical name. The legacy `test_commit:` field is **renamed** to `Commit:` in both modes — old name not accepted. |
| `Red tests:` | ✅ (auto-tdd) | — | List or count of red tests after Tester commits. |
| `Tests written:` | — | ✅ (auto-harden) | Count of NEW tests added in this phase (excludes Phase 3 unit tests). |
| `Tests passing:` | — | ✅ (auto-harden) | `<passing> / <total>` count after the run. |
| `Test attempts:` | — | ✅ (auto-harden) | `1 \| 2 \| 3` — caps at 3 per `agents/tester/index.md` Test Failure Recovery. |
| `Coverage:` | — | ✅ (auto-harden) | Final coverage percent and the configured threshold. |
| `Blockers:` | ✅ | ✅ | |

`Phase:` for Tester is `3` (auto-tdd) or `5` (auto-harden).

### Reviewer — `agents/reviewer/index.md` + `pre-pr.md` + `pr-comment-analysis.md` + `request-triage.md`

Four modes share an agent but have distinct contracts. `Verdict:` carries the
routing decision; the enum varies per mode.

| Field | Phase 3 / 5 (`index.md`) | Phase 6 (`pre-pr.md`) | Phase 7 (`pr-comment-analysis.md`) | Inter-gate (`request-triage.md`) |
|-------|--------------------------|------------------------|------------------------------------|----------------------------------|
| `Mode:` | optional (omittable) | `pre-pr` | `pr-comment-analysis` | `request-triage` |
| `Repo:` | ✅ | ✅ | ✅ | ✅ |
| `Repo path:` | ✅ | ✅ | ✅ | ✅ |
| `Verdict:` | `APPROVED \| CHANGES_REQUESTED` | `APPROVED \| APPROVED_WITH_CONCERNS \| CHANGES_REQUESTED` | `ANALYSIS_COMPLETE \| ANALYSIS_PARTIAL \| PLAN_NOT_FOUND` | `TRIAGE_COMPLETE \| TRIAGE_PARTIAL \| PLAN_NOT_FOUND` |
| `Spec compliance:` | ✅ | — | — | — |
| `Spec issues:` | ✅ | — | — | — |
| `Code quality verdict:` | ✅ | — | — | — |
| `Worktree reviewed:` | ✅ | — | — | — |
| `Branch reviewed:` | — | ✅ | — | — |
| `AC coverage:` | — | ✅ | — | — |
| `Task coverage:` | — | ✅ | — | — |
| `Test coverage (new/modified code):` | — | ✅ | — | — |
| `Contracts verified:` | — | ✅ (multi-repo only) | — | — |
| `Comments analysed:` | — | — | ✅ | — |
| `Requests triaged:` | — | — | — | ✅ |
| `In-Scope Bug:` / `In-Scope AC Miss:` / `Out-of-Scope:` / `Plan Conflict:` / `Duplicate:` / `Invalid:` | — | — | — | ✅ |
| `Valid:` / `Invalid:` / `Partial:` / `Unclassified:` | — | — | ✅ (`Unclassified:` non-zero ⇒ `Verdict: ANALYSIS_PARTIAL`) | `Unclassified:` ✅ (non-zero ⇒ `Verdict: TRIAGE_PARTIAL`) |
| `Build verified:` | ✅ | ✅ | — | — |
| `Tests verified:` | ✅ | — | — | — |
| `Comments:` | ✅ | — | — | — |
| `Critical issues:` | ✅ | ✅ | — | — |
| `Warnings:` | — | ✅ | — | — |
| `Suggestions:` | — | ✅ | — | — |
| `Review comments:` | ✅ (full `[S]/[R]/[T]` list when `Verdict: CHANGES_REQUESTED`; `none` when `APPROVED`) | — | — | — |
| `Blockers:` | ✅ | ✅ | ✅ | ✅ |

`Outcome:` for the reviewer is `SUCCESS | FAILED`. `Verdict:` is the
authoritative routing signal in Phase 3/5/6/7 and the inter-gate triage; the
orchestrator's decision matrices key off Verdict, not Outcome (see
`dev-workflow/commands/develop.md`, `create-pr.md`, and `handle-request.md`).

## Hook enforcement floor

`scripts/_agent_status_check.py` enforces the **structural** floor at
SubagentStop:

1. The literal phrase `📋 AGENT STATUS` appears in the response's final tail
   window (sized as `max(5, min(50, line_count // 4))`).
2. The block contains at least one of `Outcome:` or `Verdict:` with a non-empty
   value.
3. The block contains `Agent:` with a recognized name (`planner`, `developer`,
   `tester`, `reviewer`).
4. **When** the SubagentStop payload carries `agent_type` matching a known agent
   AND the declared `Agent:` value matches, the per-agent universal-floor
   fields above are validated (everything in the floor table, not the
   mode-specific tables).

Mode-specific field enforcement is intentionally left to **doc-grep regression
tests** under `tests/skills/status-schema.test.sh` — those check every agent
file's status-block example against this schema. The hook stays simple and
non-blocking on field shape; the doc-grep tests catch drift in the contract.

## Adding a new field

1. Add the field to the relevant per-agent / per-mode table above.
2. Update the status-block example in the agent's `index.md` (or mode file).
3. Add a doc-grep assertion in `tests/skills/status-schema.test.sh`.
4. If the field is in the universal floor, also update
   `scripts/_agent_status_check.py`'s `_FLOOR_FIELDS_PER_AGENT` map and the
   hook test suite.

## Field-name canonical forms

These are the canonical names. Renames have happened; the old names are not
accepted by the doc-grep checks:

| Canonical | Legacy / non-canonical | Status |
|-----------|------------------------|--------|
| `Commit:` | `test_commit:` (Tester auto-tdd) | Renamed in this schema. |
| `Verdict:` | (none — but historically absent on `pr-comment-analysis`) | Universal across all reviewer modes. |
| `Tracker path:` | (none — was not declared on Planner) | New on Planner Phase 2. |
| `Plan path:` | (none — was not declared on Planner) | New on Planner Phase 2. |
| `Worktree branch:` | (auto-harden previously missing it) | Universal across worktree-aware modes. |
| `Build result:` | `Build:` | Renamed on Developer to match the emitted template — value carries the warning count, not just PASS/FAIL. |
| `Build verified:` | `Build:` | Renamed on Reviewer Phase 3/5/6 to match the emitted template — value carries the warning count and `skipped (spec failed)` state. |
| `Tests verified:` | `Tests:` | Renamed on Reviewer Phase 3/5 to match the emitted template — value carries `not applicable (Phase 3)` for tasks where the reviewer skipped a test run. |
| `Self-review:` | (none — was not declared on Developer) | Required on Developer; `FAIL` invalid alongside `Outcome: SUCCESS`. |

## Why-no-test enumeration (reserved for M-20)

The `Why-no-test:` field is **reserved** here so M-20 (`TDD Red-Verify
Enforcement`) can extend the allowed-values enum without re-versioning this
schema. M-20 owns the canonical values; this paragraph reserves the field name
and its allowed-position on the Developer and Tester `auto-tdd` modes per
CC-02.4 IMPL-01-12 sub-step (d).

## Machine-readable contract (CC-02.4.1)

Per CC-02.4.1, the `agent-status-check` hook reads the YAML block below — never
the prose tables above — at startup. If this YAML block is malformed (YAML
parse error), the hook exits 2 with `status-schema.md is malformed — cannot
enforce contract`. Wiring the hook to read this YAML (rather than
hard-coded constants) is owned by M-23.

The enum values below match the **canonical post-reconciliation vocabulary**
(in use across every agent's `index.md` example block and the SubagentStop
hook). As of 2026-05-17, cc-conventions.md CC-02.4 was amended to adopt the
brownfield enum (`SUCCESS | PARTIAL | FAILED | BLOCKED | DONE_WITH_CONCERNS |
REFUSED`) — the original design proposal of `SUCCESS | FAILURE | BLOCKED |
NO_OP | REFUSED` was retired in favour of the implementation's richer
semantics: `PARTIAL` (degraded success), `DONE_WITH_CONCERNS` (developer
correctness flag), and the adjective-form `FAILED` matching every existing
fixture. The convention and this schema are now byte-aligned on the enum.

```yaml
# agents/shared/status-schema.md — machine-readable contract
# > Owner: cross-cutting
# > Version: 1.0
schema_version: "1.0"
universal_required:
  # Aligned with the legacy hook's actual enforcement: Agent + Next action are
  # universal; Outcome is required EXCEPT when Verdict is present (substitution
  # rule documented in the prose above — reviewer modes use Verdict for the
  # routing signal). Phase is documented as universal in cc-conventions.md
  # CC-02.4 but historically optional in the harness; bumping it to required
  # would invalidate every existing reviewer fixture, so it is enforced via
  # the per-role-mode list instead (where it IS canonically required).
  - Agent
  - Next action
outcome_enum:
  - SUCCESS
  - PARTIAL
  - FAILED
  - BLOCKED
  - DONE_WITH_CONCERNS
  - REFUSED   # M-23 IMPL-23-05: distinct from BLOCKED — agent explicitly refused per CC-02.5; no auto-retry.
verdict_enum:
  reviewer_index:
    - APPROVED
    - CHANGES_REQUESTED
  reviewer_pre_pr:
    - APPROVED
    - APPROVED_WITH_CONCERNS
    - CHANGES_REQUESTED
  reviewer_pr_comment_analysis:
    - ANALYSIS_COMPLETE
    - ANALYSIS_PARTIAL
    - PLAN_NOT_FOUND
  reviewer_request_triage:
    - TRIAGE_COMPLETE
    - TRIAGE_PARTIAL
    - PLAN_NOT_FOUND
roles:
  planner:
    canonical_name: ai-sdlc-planner
    modes:
      requirements:
        required: [Startup reads, Files written, Files failed, Blockers]
        optional: [Tracker path, Plan path]
      plan-generator:
        required: [Startup reads, Files written, Files failed, Tracker path, Plan path, Blockers]
        optional: []
  developer:
    canonical_name: ai-sdlc-developer
    modes:
      auto:
        required: [Repo, Repo path, Language, Worktree, Worktree branch, Build result, Build attempts, Commit, Files changed, Self-review, Concerns, Blockers]
        optional: [Why-no-test]
  tester:
    canonical_name: ai-sdlc-tester
    modes:
      auto-tdd:
        required: [Mode, Repo, Repo path, Language, Worktree, Worktree branch, Commit, Red tests, Blockers]
        optional: [Why-no-test]
      auto-harden:
        required: [Mode, Repo, Repo path, Language, Worktree, Worktree branch, Commit, Tests written, Tests passing, Test attempts, Coverage, Blockers]
        optional: []
  reviewer:
    canonical_name: ai-sdlc-reviewer
    modes:
      auto:
        required: [Repo, Repo path, Verdict, Spec compliance, Spec issues, Code quality verdict, Worktree reviewed, Build verified, Tests verified, Comments, Critical issues, Review comments, Blockers]
        optional: []
      pre-pr:
        required: [Mode, Repo, Repo path, Verdict, Branch reviewed, AC coverage, Task coverage, "Test coverage (new/modified code)", Build verified, Warnings, Suggestions, Critical issues, Blockers]
        optional: [Contracts verified]
      pr-comment-analysis:
        required: [Mode, Repo, Repo path, Verdict, Comments analysed, Valid, Invalid, Partial, Unclassified, Blockers]
        optional: []
      request-triage:
        required: [Mode, Repo, Repo path, Verdict, Requests triaged, Unclassified, Blockers]
        optional: ["In-Scope Bug", "In-Scope AC Miss", "Out-of-Scope", "Plan Conflict", Duplicate, Invalid]
required_when_outcome:
  FAILED: [Blockers]
  BLOCKED: [Blockers]
  PARTIAL: [Blockers]
  DONE_WITH_CONCERNS: [Concerns]
contradictions:
  # forbidden field-value combinations
  - { all_of: [{ Outcome: SUCCESS }, { Self-review: FAIL }] }
  - { all_of: [{ Verdict: ANALYSIS_PARTIAL }, { Unclassified: "0" }] }
  - { all_of: [{ Verdict: TRIAGE_PARTIAL }, { Unclassified: "0" }] }
allowed_combinations:
  - { Outcome: SUCCESS, Self-review: PASS }
  - { Outcome: DONE_WITH_CONCERNS, Concerns: "<non-empty>" }
  - { Outcome: BLOCKED, Blockers: "<non-empty>" }
  - { Outcome: FAILED, Blockers: "<non-empty>" }
```

> **Reconciliation note (closed 2026-05-17)**: the cc-conventions.md CC-02.4
> design enum was amended to `SUCCESS | PARTIAL | FAILED | BLOCKED |
> DONE_WITH_CONCERNS | REFUSED` to match the brownfield harness vocabulary —
> the prior design enum (`SUCCESS | FAILURE | BLOCKED | NO_OP | REFUSED`) was
> retired. Implementation is now byte-aligned with the convention; no further
> action is needed.

# AGENT STATUS Block Schema

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
| `Agent:` | enum | One of `planner`, `developer`, `tester`, `reviewer`. Used by `agent-status-check` for per-agent validation when `agent_type` is missing from the SubagentStop payload. |
| `Phase:` | enum | `1`, `2`, `3`, `5`, `6`, or `7`. The phase the agent ran under. |
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
| `Worktree:` | ✅ | Worktree path from `WORKTREE_CTX`, or `not used (direct branch)` when `worktree_failed: true`. |
| `Worktree branch:` | ✅ | Worktree branch, or `n/a` when `worktree_failed: true`. |
| `Commit:` | ✅ | Implementation commit hash, or `none`. |
| `Build:` | ✅ | `PASS \| FAIL`. |
| `Tests:` | ✅ | `PASS \| FAIL` (count of pass/fail tests, e.g. `12 passed, 0 failed`). |
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
| `Worktree:` | ✅ | ✅ | Same fallback wording as Developer. |
| `Worktree branch:` | ✅ | ✅ | Required in auto-harden too (the auto-harden contract previously omitted this — closed by this schema). |
| `Commit:` | ✅ | ✅ | Canonical name. The legacy `test_commit:` field is **renamed** to `Commit:` in both modes — old name not accepted. |
| `Red tests:` | ✅ (auto-tdd) | — | List or count of red tests after Tester commits. |
| `Coverage:` | — | ✅ (auto-harden) | Final coverage percent and the configured threshold. |
| `Blockers:` | ✅ | ✅ | |

`Phase:` for Tester is `3` (auto-tdd) or `5` (auto-harden).

### Reviewer — `agents/reviewer/index.md` + `pre-pr.md` + `pr-comment-analysis.md`

Three modes share an agent but have distinct contracts. `Verdict:` carries the
routing decision; the enum varies per mode.

| Field | Phase 3 / 5 (`index.md`) | Phase 6 (`pre-pr.md`) | Phase 7 (`pr-comment-analysis.md`) |
|-------|--------------------------|------------------------|------------------------------------|
| `Mode:` | optional (omittable) | `pre-pr` | `pr-comment-analysis` |
| `Repo:` | ✅ | ✅ | ✅ |
| `Repo path:` | ✅ | ✅ | ✅ |
| `Verdict:` | `APPROVED \| CHANGES_REQUESTED` | `APPROVED \| APPROVED_WITH_CONCERNS \| CHANGES_REQUESTED` | `ANALYSIS_COMPLETE \| ANALYSIS_PARTIAL \| PLAN_NOT_FOUND` |
| `Worktree reviewed:` | ✅ | — | — |
| `Contracts verified:` | — | ✅ (multi-repo only) | — |
| `Comments analysed:` | — | — | ✅ |
| `Valid:` / `Invalid:` / `Partial:` / `Unclassified:` | — | — | ✅ (`Unclassified:` non-zero ⇒ `Verdict: ANALYSIS_PARTIAL`) |
| `Build:` / `Tests:` | ✅ | ✅ | — |
| `Blockers:` | ✅ | ✅ | ✅ |

`Outcome:` for the reviewer is `SUCCESS | FAILED`. `Verdict:` is the
authoritative routing signal in Phase 3/5/6/7; the orchestrator's decision
matrices key off Verdict, not Outcome (see `dev-workflow/commands/develop.md`
and `create-pr.md`).

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

# Ad-Hoc Request Handling

> Authoritative references: [summary-render](../context/summary-render.md), [phase-re-entry](../context/phase-re-entry.md), [timestamp](../context/timestamp.md), [comment-routing](../context/comment-routing.md), [workflow-paths](../context/workflow-paths.md)

> **Path resolution (M-14 IMPL-14-02)**: every inline reference to `ai/plans/<id>.md` / `ai/tasks/<id>.md` in this command is the **legacy** layout. Resolve actual paths via `ai/*-<work-item-id>/{plan,tracker}.md` (new canonical layout per [workflow-paths](../context/workflow-paths.md)); fall back to the legacy paths during the migration window.

<!-- Changed by: dev-workflow-plan.md [M-06] [IMPL-06-03, IMPL-06-04]
     Reason: Cite shared snippets + add canonical-spec header per CC-04.3 / CC-07.3 / CC-08.2.
     The Step 7b re-entry sequence (P3 re-entry + P5 re-trigger) is the GAP-07 duplicate
     that now defers to `phase-re-entry.md` rather than inlining the same prose as review-response.md.
     CC conventions applied: CC-04.3, CC-07.3, CC-08.2. -->

**Phase**: Inter-gate (3, 4, 5, or at GATE #2 / GATE #3)
**Actors**: Reviewer (triage), Planner (task creation), Orchestrator, Human gate (GATE #5)

> **Tracker schema reference**: every token, section, and enum mentioned
> below is canonically defined in [`../../plan-generator/tracker-schema.md`](../../plan-generator/tracker-schema.md).
> Reach for that page when this file mentions a token without expanding it.

## Overview

Handles ad-hoc requests submitted between approval gates. Every request is **triaged against the approved plan and AC** before any code work begins. In-scope items become tasks (with human confirmation) under `## Ad-hoc Tasks`; out-of-scope items are surfaced with explicit options — never merged silently.

## Usage

Entry points:

1. **Direct phase mode** (`gate-2`, `gate-3`, `mid-phase`): The orchestrator handles the request **synchronously and in-line** on the current turn; Steps 1–6 run immediately, then control returns to the lane main loop.

   **Concurrency model**: background agents continue executing independently. The orchestrator **cannot service their completion notifications until it finishes the current request-handling turn** (including GATE #5 — potentially a long pause). Deferred completions are processed when the orchestrator returns to the lane loop. Background agents are not preempted or paused — they complete on their own clock.
2. **At GATE #2** (`approve-impl.md`): human selects `REQUEST <description>`.
3. **At GATE #3** (`create-pr.md` Step 3): human selects `REQUEST <description>`.

In all three entry points the orchestrator captures the request text verbatim.

### Scheduling semantics (Non-Negotiable)

Mid-phase requests do **not** preempt in-flight tasks. Ad-hoc rows append after existing pending rows; standard lane loop picks them up in tracker order. This eliminates the queue / poll-point design: there is no orchestrator-side queue, no checkpoint draining.

## Prerequisites

- Plan approved and committed (Phase 2 complete).
- Task tracker exists. Batch multiple simultaneous requests — one Reviewer invocation per repo.

## Steps

### Step 1 — Capture and Number Requests

Assign each request a sequential `[AHR-<n>]` ID. Determine `<n>` from the maximum across: (1) `## Pending Requests` Re-renders column, (2) `## Ad-hoc Tasks` Notes `ad-hoc: [AHR-<n>]` tokens, (3) `## Deferred Requests` Request ID column — add 1. Start at 1 if none exist.

Record: `Source` (gate-2 | gate-3 | mid-phase), `Phase at submission`, `Repos in scope` (from request text; default to all tracker repos if not named).

**Write a `## Pending Requests` ledger row to the tracker** via Read+Write (durable record — used by Step 5's re-render bound to survive session interruptions). Schema authoritative in [`tracker-schema.md`](../../plan-generator/tracker-schema.md):

```
## Pending Requests

| Request ID | Submitted | Source | Re-renders | Notes |
|------------|-----------|--------|------------|-------|
| [AHR-<n>]  | <date -u +"%Y-%m-%d %H:%M UTC"> | <gate-2 \| gate-3 \| mid-phase> | 0 | <verbatim request text — single-line; multi-line text uses `\n` literal> |
```

**Order vs the disambiguation prompt**: resolve `Repos in scope` first (substring-matching; trigger disambiguation prompt if 2+ matches). Only write the ledger row **after** scope resolution succeeds. If the human picks `[5] Cancel`, return from Step 1 without writing the row.

Row is deleted at terminal state (task created → delete; deferred → move to `## Deferred Requests`). If session interrupted, the next session reads `## Pending Requests` and resumes with the recorded `Re-renders` count.

### Step 2 — Reviewer: Triage Each Request

For each repo, invoke `@ai-sdlc-reviewer` (`mode: request-triage`, `run_in_background: true`, name: `reviewer-triage-<repo-name>`):

```
@ai-sdlc-reviewer Triage ad-hoc human requests for Story $ARGUMENTS.
MODE: request-triage
[Include LANGUAGE_CTX — build-cmd, test-cmd; omit format-cmd]
TRIAGE CONTEXT: Repo, Repo path, Feature branch, Default branch, Plan path, Tracker path, Story ID, Source, Phase
REQUESTS TO TRIAGE: [AHR-<n>] <verbatim text> ...
Classify each and produce the Ad-Hoc Request Triage Report (see agents/reviewer/request-triage.md).
```

**Launch all repo reviewers in a single message.** Wait for all to complete.

### Step 3 — Merge Multi-Repo Reports

Merge reports (one classification per `[AHR-<n>]` per repo — a single request can be `IN_SCOPE_BUG` in repo A and `OUT_OF_SCOPE` in repo B). Present separated by repo with merged summary:
`Total across all repos — In-Scope Bug: N | In-Scope AC Miss: N | Out-of-Scope: N | Plan Conflict: N | Duplicate: N`

### Step 4 — Present Triage Report (HUMAN GATE #5)

Display the full merged report. Gate uses a **per-decision matrix** (one row per repo×AHR pair) to cleanly handle: **A single `[AHR-<n>]` classified differently across repos** and **mixed batches** (some in-scope, some not). One row per repo×AHR pair, each answered independently.

#### Decision-matrix prompt

For every `(repo, [AHR-<n>])` pair the Reviewer classified, emit one row in the
matrix below. Group rows by `[AHR-<n>]` so the human can see how a single request
splits across repos.

```
## Ad-Hoc Request Triage — Decisions

<display full triage report(s) above the matrix>

| # | Request | Repo | Classification | Choose |
|---|---------|------|----------------|--------|
| 1 | [AHR-1] | repoA | IN_SCOPE_BUG     | [1] Confirm  [2] Skip                                |
| 2 | [AHR-1] | repoB | OUT_OF_SCOPE     | [a] Expand scope  [b] Defer as new story  [c] Withdraw |
| 3 | [AHR-2] | repoA | PLAN_CONFLICT    | [a] Expand scope  [b] Defer as new story  [c] Withdraw |
|   |         |       |                  |     Conflicting plan section: §<anchor>              |
| 4 | [AHR-3] | repoA | DUPLICATE        | [d] Acknowledge (no task)  [e] Override → Confirm   |
|   |         |       |                  |     Already covered by: T<n> (or [AHR-<m>])         |
| 5 | [AHR-4] | repoA | INVALID          | [d] Acknowledge (no task)  [e] Override → Confirm   |
|   |         |       |                  |     Reason: <reviewer one-liner>                    |
| 6 | [AHR-5] | (any) | UNCLASSIFIED     | [f] Re-triage with hint  [g] Skip  [h] Override → <class> |

Global option (applies to every row not answered individually):
  [SKIP-ALL] — skip the entire batch, resume the previous gate

Reply with one choice per row (`1 → [1]`, `2 → [b]`, …) or [SKIP-ALL].
```

#### Choice → action mapping

| Choice | Action |
|--------|--------|
| `[1] Confirm`           | The (repo, AHR) pair becomes an ad-hoc task at Step 6. |
| `[2] Skip`              | Recorded in `## Deferred Requests` with disposition `ACKNOWLEDGED`. |
| `[a] Expand scope`      | Runs the snapshot → `MODE: plan-amendment` → scoped GATE #1 → restore-or-re-triage sequence (Step 5 below). |
| `[b] Defer as new story`| Recorded in `## Deferred Requests` with disposition `DEFERRED_AS_NEW_STORY`. The orchestrator surfaces a reminder to open a new work item; it does NOT call the provider adapter. |
| `[c] Withdraw`          | Recorded in `## Deferred Requests` with disposition `WITHDRAWN`. |
| `[d] Acknowledge`       | Recorded in `## Deferred Requests` with disposition `ACKNOWLEDGED`. |
| `[e] Override → Confirm`| Treats the row as if `IN_SCOPE_BUG`. Becomes an ad-hoc task at Step 6. |
| `[f] Re-triage with hint` | Re-invoke the Reviewer for this row only with the human's hint appended; re-render the matrix. |
| `[g] Skip`              | Recorded in `## Deferred Requests` with `ACKNOWLEDGED`. |
| `[h] Override → <class>`| Treats the row as the human-named classification (must be one of the six). Routing per the override class — see *Override-class routing* below. |
| `[SKIP-ALL]`            | Every row not answered individually is recorded as `ACKNOWLEDGED`. The previous gate resumes. |

#### Override-class routing (`[e]` and `[h]`)

`[e]` is shorthand for `[h] → IN_SCOPE_BUG`. `[h]` accepts any of the six classifications:

| Override class | Routing |
|----------------|---------|
| `IN_SCOPE_BUG` / `IN_SCOPE_AC_MISS` | Step 6 (task creation). Same as `[1] Confirm`. |
| `DUPLICATE` / `INVALID` | `## Deferred Requests` with `ACKNOWLEDGED`. Same as `[d]`. |
| `OUT_OF_SCOPE` | **Matrix re-renders for this row only** with `[a]/[b]/[c]` choice set. `re_render_count` +1. |
| `PLAN_CONFLICT` | Same as `OUT_OF_SCOPE`. Orchestrator asks human to identify the conflicting section (no anchor from Reviewer). `re_render_count` +1. |

`[h] → OUT_OF_SCOPE` and `[h] → PLAN_CONFLICT` participate in the matrix re-render bound (3 rounds max).

#### Special row: UNCLASSIFIED (TRIAGE_PARTIAL handling)

When `Verdict: TRIAGE_PARTIAL`, every unclassified `[AHR-<n>]` appears with `Classification: UNCLASSIFIED` and `[f] / [g] / [h]` choices. `TRIAGE_PARTIAL` never falls through silently.

#### Special verdict: PLAN_NOT_FOUND

`Verdict: PLAN_NOT_FOUND` → `Outcome: FAILED`. The orchestrator MUST NOT fabricate a plan path — escalate verbatim, pause. Human can rerun `/init-workspace`, restore plan from VCS, or kill the request.

### Step 5 — Handle Human Response

Parse the human's reply into one decision per row. Row actions share the plan file — the order is **non-negotiable**:

#### Row-action execution order

1. **All `[a] Expand scope` rows first** — batch into one `MODE: plan-amendment` invocation.
2. **All `[f] Re-triage with hint` rows next** — re-invoke Reviewer against the (possibly amended) plan.
3. **All `[1] / [e] / [h]→IN_SCOPE_* / [h]→DUPLICATE` rows next** — go to Step 6.
4. **All remaining rows last** — `[2] / [d] / [g] / [b] / [c] / [h]→OUT_OF_SCOPE / [h]→PLAN_CONFLICT` — append to `## Deferred Requests`.

#### Matrix re-render bound

`[f]` and `[a]` rejection paths can trigger a re-render. **The matrix re-renders at most 3 times per `[AHR-<n>]`** (initial = round 0).

##### Persistence

The `Re-renders` column on the `## Pending Requests` ledger row is **the single source of truth for the counter** — durable across session interruptions. Notes column carries verbatim request text (Summary fallback). The two cells have disjoint roles — no shadow state, no normalisation contract needed.

##### Increment rules

| Trigger | Increment |
|---------|-----------|
| Initial Step 4 render | 0 |
| `[f] Re-triage with hint` | +1 |
| `[h] Override → OUT_OF_SCOPE` or `[h] → PLAN_CONFLICT` | +1 |
| `[a] Expand scope` rejected at scoped GATE #1 | +1 |
| `[a] Expand scope` approved → Reviewer re-triages | +1 |

At `Re-renders == 3`, strip `[f]` and surface note. Human must terminate via remaining choices or `[SKIP-ALL]`.

##### Worked example

`[AHR-1]` submitted at GATE #2, classified `OUT_OF_SCOPE` (round 0, `Re-renders: 0`):

| Round | Human action | Re-renders after |
|-------|--------------|------------------|
| 1 | `[a] Expand scope` approved → re-triages | 1 |
| 2 | (now `IN_SCOPE_BUG`; picks `[2] Skip`) | 1 (terminal) |

Worst case:

| Round | Human action | Re-renders after |
|-------|--------------|------------------|
| 1 | `[a]` → amendment rejected | 1 |
| 2 | `[a]` again → second amendment rejected | 2 |
| 3 | `[h] Override → PLAN_CONFLICT` | 3 |
| — | would-be 4th render — bound enforced | — |

`[1]` / `[e] → IN_SCOPE_BUG` / `[h] → IN_SCOPE_BUG` / `[h] → IN_SCOPE_AC_MISS` / `[h] → DUPLICATE` / `[h] → INVALID` are **terminal** — they route to disposition and never re-render. Only choices in the Increment rules table tick the counter; every other choice is +0.

#### Action handlers

Apply in the order pinned above.

**`[1] Confirm` / `[e] Override → Confirm` / `[h] → IN_SCOPE_*`:** Collect `(repo, [AHR-<n>])` pairs → Step 6.

**`[2] Skip` / `[d] Acknowledge` / `[g] Skip` / `[h] → DUPLICATE/INVALID`:** Append to `## Deferred Requests` (`ACKNOWLEDGED`). Orchestrator writes directly via Read+Write — no Planner needed.

**Summary column provenance**: use Reviewer's one-liner when available. For `UNCLASSIFIED` or `[h] Override`, fall back to **the verbatim AHR request text** (recoverable from `## Pending Requests` ledger row). Multi-line text joined with `\n` literal.

**`[f] Re-triage with hint`:** Re-invoke Reviewer for that single `[AHR-<n>]` with the hint. Re-render matrix with updated row(s); already-answered rows remain.

**`[b] Defer as new story` / `[c] Withdraw`:** Append to `## Deferred Requests`. For `[b]`, surface reminder to open a new work item — orchestrator does NOT call the provider adapter.

**Rows with `[a] Expand scope` (one or more):**

1. **Snapshot the plan to disk** — Read current plan, Write copy to:
   `<WORKSPACE_ROOT>/ai/.snapshots/<plan-basename>-<YYYY-MM-DD-HHMMSS>-<uid8>.md`
   (`<uid8>` via `uuidgen … | cut -c1-8`; the uid8 suffix prevents same-second filename collisions — without it, two snapshots in the same UTC second would overwrite each other). Also cache as `PLAN_SNAPSHOT` in session state (fast restore path). **The on-disk copy survives session crashes** — authoritative if `PLAN_SNAPSHOT` is evicted. snapshot is workspace-agnostic; `bash-write-guard` blocks Bash writes to `ai/` — use Write tool only.
2. Invoke `@ai-sdlc-planner` with `MODE: plan-amendment` (foreground), batching all `[a]` rows into one invocation (one `## Plan Amendment — Ad-Hoc Round <N>` section per batch).
3. Re-present GATE #1 scoped to the amendment delta only.
4. **On approval**: commit plan if workspace is a git repo. **Delete the on-disk snapshot** (the orchestrator must remember the exact filename it wrote to avoid deleting a concurrent flow's snapshot). Re-invoke Reviewer in `mode: request-triage` — under amended plan it should classify as `IN_SCOPE_AC_MISS`/`IN_SCOPE_BUG`/`DUPLICATE`. Continue to Step 6.
5. **On rejection**: restore the plan. **Prefer the in-memory `PLAN_SNAPSHOT` cache** (fast path). If unavailable, **Read the on-disk snapshot** at the exact `<plan-basename>-<timestamp>-<uid8>.md` path. Write to overwrite plan file. Delete snapshot. Fall through to `[b]`/`[c]` in `## Deferred Requests`.
6. **On partial revision**: re-invoke Planner with revision instructions. On-disk snapshot unchanged (always points pre-amendment).

Rollback MUST use Write tool — not `cp`, `mv`, or `>`.

**`[SKIP-ALL]`:** All unanswered rows → `## Deferred Requests` (`ACKNOWLEDGED`). Skip Step 6, proceed to Step 8.

### Step 6 — Planner: Append Ad-Hoc Tasks to Tracker

Invoke `@ai-sdlc-planner` with `MODE: ad-hoc-tasks` (foreground). Behaviour documented in `skills/plan-generator/SKILL.md` → **Ad-Hoc Task Mode**:

```
@ai-sdlc-planner Append ad-hoc tasks to the existing tracker for Story $ARGUMENTS.
MODE: ad-hoc-tasks
CONTEXT: Tracker path, Plan path, Test-outline path, Story ID, Batch <N> (count of existing `## Ad-hoc Tasks (Batch …)` headings + 1), Source, Timestamp

CONFIRMED IN-SCOPE REQUESTS:
[AHR-<n>] Repo | Classification | Reviewer reasoning | Proposed task | Affected files
[AHR-<m>] ...

Instructions:
1. Read tracker, plan, and test-outline. Find highest Task ID across all sections.
2. Append one task row per AHR under `## Ad-hoc Tasks (Batch <N>)` in the tracker.
3. Append a `## Test Outline — Ad-Hoc Batch <N>` section to **`test-outline.md`** (NOT plan.md), with one `## T<n>: …` block per new task (Subject_Scenario_Outcome convention). Keep the file in lock-step with the new tracker rows.
4. Regenerate `## Dependency Graph` (new tasks → T-TEST-<RepoName>).
5. Record `Ad-hoc requests started` in Workflow Metrics (first batch only).
6. Save and verify tracker and test-outline.
```

On `PARTIAL`/`FAILED` follow `orchestrator-rules.md`. On `SUCCESS`, record `Ad-hoc requests started` if not already set.

### Step 7 — Re-Enter TDD Development Loop

Read and execute `commands/develop.md`.

> **Only process tasks whose row lives under a `## Ad-hoc Tasks (Batch …)` heading and whose Status is ⏳ Pending.**

All Phase 3 rules apply (TDD/direct paths, worktree isolation, sequential within repo, parallel across repos, squash-merge on approval). After all ad-hoc tasks ✅ Done, proceed to Step 7b.

### Step 7b — Re-trigger Phase 5 hardening on affected repos

Post-Phase-5 ad-hoc batches (`source: gate-3` or post-Phase-5 `mid-phase`) introduce new production code that has never been through the 90% coverage gate (see `review-response.md` Step 8b for full rationale). This step is a no-op for `source: gate-2` batches (Phase 5 hasn't run yet).

For each repo where this batch added at least one task, check `T-TEST-<RepoName>` Status:

- **`Status: ✅ Done`** → re-trigger:
  1. Set `T-TEST-<RepoName>` → `🔧 In Progress` (legal `✅ Done → 🔧 In Progress` per `tracker-schema.md`; overwrites `Started` on T-TEST row — original Phase 5 start preserved in `Test hardening started` Workflow Metrics).
  2. Invoke `commands/test.md` Step 1 (auto-harden Tester) and Step 2 (Reviewer).
  3. On `APPROVED` → set `T-TEST-<RepoName>` → `✅ Done`, stamp `Completed`.
  4. On `CHANGES_REQUESTED` → loop per standard Phase 5 handling.

- **`Status` is anything else** → no-op for `source: gate-2` batches (Phase 5 hasn't completed; upcoming run covers the new code).

Multiple repos parallel via `run_in_background: true`. After all re-triggered T-TESTs return to ✅ Done, proceed to Step 8.

### Step 8 — Return to the Previous Gate

Set `Ad-hoc requests completed` (Workflow Metrics).

Resume the interrupted gate:

- **Source `gate-2`**: re-present GATE #2 (`commands/approve-impl.md`).
- **Source `gate-3`**: re-run Step 2 (Pre-PR Holistic Review) of `commands/create-pr.md`, then re-present GATE #3.
- **Source `mid-phase`**: **re-scan lane state, do not assume the previous lane is still active.** Deferred completion notifications may have accumulated. The orchestrator MUST:
  1. Process any deferred completion notifications first (in `develop.md` Step 2 order).
  2. Re-read the tracker; re-enter `develop.md` Step 1 for each lane with pending rows (including newly-appended ad-hoc rows). Do NOT assume any specific lane is mid-task.

## Tracker Schema — Ad-Hoc Tasks and Deferred Requests

Two sections appended below the main task table (owned by Planner; orchestrator updates Status/Verdict/Commits per standard transitions). Full schema in [`tracker-schema.md`](../../plan-generator/tracker-schema.md).

```markdown
## Ad-hoc Tasks (Batch <N>)

| Task ID | Repo | Title | Status | Reviewer Verdict | Commit(s) | Notes |
|---------|------|-------|--------|------------------|-----------|-------|
| T<next-n> | <repo-name> | <≤ 60-char title> | ⏳ Pending | — | — | ad-hoc: [AHR-<n>] · source: <gate-2 \| gate-3 \| mid-phase> · submitted: <YYYY-MM-DD HH:MM UTC> · test-required: <true \| false> |

## Deferred Requests

| Request ID | Submitted | Source | Classification | Disposition | Summary |
|------------|-----------|--------|----------------|-------------|---------|
| [AHR-<n>] | <YYYY-MM-DD HH:MM UTC> | <gate-2 \| gate-3 \| mid-phase> | <class> | <DEFERRED_AS_NEW_STORY \| WITHDRAWN \| ACKNOWLEDGED> | <one-line text> |
```

`ad-hoc: [AHR-<n>]` is the canonical provenance marker — do not rename it.

## Re-Entry and Single-Repo Compat

Invokable multiple times (each creates a new `## Ad-hoc Tasks (Batch <N>)` heading; prior batches stay Done). `[AHR-<n>]` counter is globally monotonic. Single-repo behaves identically — one Reviewer, one gate, one Planner, one dev loop.

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

This command handles ad-hoc requests the human submits between approval gates — typically:
- An issue spotted while exercising the implementation before Phase 4 approval.
- A change request raised at GATE #2 or GATE #3 instead of `APPROVED`.
- A drive-by observation during Phase 3 / Phase 5 while agents run in the background.

Every request is **triaged against the approved plan and acceptance criteria** before any code work begins. In-scope items are auto-decomposed into tasks (with human confirmation), follow the standard TDD path, and land in a separate `## Ad-hoc Tasks` table in the tracker so the original DAG stays intact. Out-of-scope or plan-conflicting items are surfaced to the human with explicit options — they never merge silently.

## Usage

The orchestrator enters this command in three ways:

1. **Direct phase mode**: `/dev-workflow request <Work-Item-ID> "<request text>"` — usable mid-phase while Phase 3 or Phase 5 agents run in the background. The orchestrator handles the request **synchronously and in-line**: Steps 1–6 below run immediately on the orchestrator turn that received the request, then control returns to the lane main loop.

   **Concurrency model (read carefully):** background agents spawned with `run_in_background: true` are independent processes — they continue executing on their own while the orchestrator handles the request. But the orchestrator is a single turn-based loop and **cannot service their completion notifications until it finishes the current request-handling turn** (which includes a human gate at Step 4 — potentially a long pause). When the orchestrator returns control to the lane main loop after Step 6, it processes any background-agent completions that arrived during the request-handling turn in the usual order (per `develop.md` Step 2). Background agents are not preempted, killed, or paused — they simply complete on their own clock and their completion handlers are deferred.

   The practical impact: a lane whose reviewer completes mid-request-handling won't see its squash-merge until after GATE #5 closes. That latency is inherent to the single-loop orchestrator and is acceptable for the typical request-handling time (< 10 minutes). Lanes pick up new ad-hoc rows on their next idle-cycle (after the deferred completion handlers run and their next task is launched), per the standard tracker-order task picker in `develop.md` Step 1.
2. **At GATE #2** (in `approve-impl.md`): the human selects `REQUEST <description>` instead of `APPROVED` / `CHANGES`.
3. **At GATE #3** (in `create-pr.md` Step 3): the human selects `REQUEST <description>` instead of `APPROVED` / `DRAFT` / `CHANGES`.

In all three entry points the orchestrator captures the request text verbatim and executes the steps below.

### Scheduling semantics (Non-Negotiable)

Mid-phase requests do **not** preempt in-flight tasks and do **not** jump the queue. Ad-hoc rows are appended to the tracker after any existing pending main-table rows in the same repo; the standard lane main loop picks them up in tracker order. If you need an ad-hoc item to run **before** more main-table work proceeds, raise the request at the next gate (GATE #2 or GATE #3) where the workflow is paused — the gate-entry paths re-enter Phase 3 scoped to the new batch and only return to the gate once the batch is ✅ Done.

This rule eliminates the queue / poll-point design: there is no orchestrator-side queue, no checkpoint draining, and no need for an explicit "next safe checkpoint" hook in `develop.md` or `test.md`. The orchestrator-as-loop-coordinator handles each user prompt as it arrives; the tracker is the only persistent state.

## Prerequisites

- Plan approved and committed (Phase 2 complete) — the request is triaged **against** the approved plan, so the plan must exist.
- Task tracker exists in `ai/tasks/` for the story.
- If multiple requests arrive in quick succession (e.g. a list of issues from a manual test pass), batch them — pass all of them to the Reviewer in a single invocation per repo.

## Steps

### Step 1 — Capture and Number Requests

For each incoming request, assign a sequential ID `[AHR-<n>]` (Ad-Hoc Request), globally numbered for the story across all entry points and rounds. Determine `<n>` by scanning the tracker for the highest existing `[AHR-<n>]` across **three** sources, in this order:

1. `## Pending Requests` (in-flight requests — see below)
2. `## Ad-hoc Tasks (Batch <N>)` rows' Notes columns (`ad-hoc: [AHR-<n>]` tokens)
3. `## Deferred Requests` rows' Request ID column

Take the maximum across all three and add 1. If none exist, start at 1.

Record the entry context for traceability:
- `Source`: `gate-2` | `gate-3` | `mid-phase` (direct command)
- `Phase at submission`: `3` | `4` | `5` | `6`
- `Repos in scope`: derived from the request text (if the human did not name a repo, default to every repo in the tracker's Repo Status section, which equals every repo in `repos-metadata.md`).

**Write a `## Pending Requests` ledger row to the tracker** via Read+Write (this row is the durable record of the in-flight request, used by Step 5's matrix re-render bound to survive session interruptions). Schema is authoritative in [`tracker-schema.md` → Pending Requests table](../../plan-generator/tracker-schema.md#pending-requests-table-section-2):

```
## Pending Requests

| Request ID | Submitted | Source | Re-renders | Notes |
|------------|-----------|--------|------------|-------|
| [AHR-<n>]  | <date -u +"%Y-%m-%d %H:%M UTC"> | <gate-2 \| gate-3 \| mid-phase> | 0 | <verbatim request text — single-line; multi-line text uses `\n` literal> |
```

**Order vs the disambiguation prompt**: resolve `Repos in scope` first (substring-match; trigger the disambiguation prompt from `orchestrator-rules.md` → *Repo-Scope Inference Bounds* if 2+ matches). Only write the ledger row **after** scope resolution succeeds. If the human picks `[5] Cancel` at the disambiguation prompt, return from Step 1 without writing the row — there is nothing to clean up. The full 4-step sub-order (assign ID → record context → resolve scope → write ledger) is enumerated in [`tracker-schema.md` → Pending Requests table → *Order vs disambiguation prompt*](../../plan-generator/tracker-schema.md#order-vs-disambiguation-prompt).

Create the section heading if it doesn't already exist. Multiple in-flight requests may share the section (e.g. a batch of requests submitted at GATE #2 — one row per `[AHR-<n>]`).

The row is **deleted** when the request reaches a terminal state — task created at Step 6 (row removed; the task itself carries the `ad-hoc: [AHR-<n>]` provenance) or deferred at Step 5 (row removed from `## Pending Requests`, appended to `## Deferred Requests`).

If a session is interrupted before Step 5 completes, the next session reads `## Pending Requests` and resumes the matrix render with the recorded `Re-renders` count.

### Step 2 — Reviewer: Triage Each Request

For each repo that may be affected by the request batch, invoke `@ai-sdlc-reviewer` with `mode: request-triage` and `run_in_background: true` (name: `reviewer-triage-<repo-name>`):

```
@ai-sdlc-reviewer Triage ad-hoc human requests for Story $ARGUMENTS.

MODE: request-triage

[Include LANGUAGE_CTX — reviewer role: include build-cmd, test-cmd; omit format-cmd]
(Templates: ../context/prompt-templates.md)

TRIAGE CONTEXT:
- Repo: <repo-name>
- Repo path: <local repo path>
- Feature branch: <team-name>/feature/<id>-<slug>
- Default branch: <main | master>
- Plan path: <ai/plans/...>
- Tracker path: <ai/tasks/...>
- Story ID: #<STORY-ID>
- Submission source: <gate-2 | gate-3 | mid-phase>
- Submission phase: <3 | 4 | 5 | 6>

REQUESTS TO TRIAGE:
[AHR-<n>] <verbatim request text>

[AHR-<m>] ...

Classify each request and produce the Ad-Hoc Request Triage Report.
See agents/reviewer/request-triage.md for instructions and report format.
```

**Launch all repo reviewers in a single message** (parallel via `run_in_background: true`). Wait for all to complete.

### Step 3 — Merge Multi-Repo Reports

If multiple repos triaged the same request batch, merge the reports. Each `[AHR-<n>]` may resolve to one classification per repo (a single request can be `IN_SCOPE_BUG` in repo A and `OUT_OF_SCOPE` in repo B if it spans both). Present them together, clearly separated by repo, with a merged summary at the top:

```
Total across all repos — In-Scope Bug: N | In-Scope AC Miss: N | Out-of-Scope: N | Plan Conflict: N | Duplicate: N
```

### Step 4 — Present Triage Report (HUMAN GATE #5)

Display the full merged report. The gate prompt uses a **per-decision matrix**
rather than a single global choice — every classification decision the Reviewer
made is presented as one row, and the human answers each row independently. This
is the only shape that handles two awkward cases cleanly:

- **A single `[AHR-<n>]` classified differently across repos** (e.g. `IN_SCOPE_BUG`
  in repo A and `OUT_OF_SCOPE` in repo B — possible because each repo's reviewer
  triages independently). One row per repo×AHR pair, each with its own choice.
- **A mixed batch** (some in-scope, some out-of-scope, some unclassified). One
  row per item; no "global confirm" forced through an out-of-scope branch.

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

`[e] Override → Confirm` is shorthand for `[h] Override → IN_SCOPE_BUG` — the
row goes to Step 6 as a task. `[h]` accepts any of the six classifications
and the orchestrator routes the row as if the Reviewer had emitted that
classification originally:

| Override class | Routing |
|----------------|---------|
| `IN_SCOPE_BUG` / `IN_SCOPE_AC_MISS` | Goes to Step 6 (task creation). Same as `[1] Confirm`. |
| `DUPLICATE` | Recorded in `## Deferred Requests` with disposition `ACKNOWLEDGED` (the human asserts another row or existing task already covers it). Same as `[d]`. |
| `INVALID` | Recorded in `## Deferred Requests` with disposition `ACKNOWLEDGED`. Same as `[d]`. |
| `OUT_OF_SCOPE` | **Matrix re-renders for this row only** with the OUT-of-scope choice set (`[a] Expand scope / [b] Defer as new story / [c] Withdraw`). The human picks one of those on the next round. The `re_render_count` increments by 1. |
| `PLAN_CONFLICT` | Same as `OUT_OF_SCOPE`. **Matrix re-renders for this row only** with the OUT-of-scope choice set. The orchestrator surfaces a one-line prompt asking the human to identify the conflicting plan section (the Reviewer didn't pick this class originally, so no section anchor exists). The human-supplied anchor goes into the `## Deferred Requests` row if `[b]` or `[c]` is chosen, or into the amendment prompt if `[a]` is chosen. The `re_render_count` increments by 1. |

`[h] → OUT_OF_SCOPE` and `[h] → PLAN_CONFLICT` thus participate in the
matrix re-render bound — three rounds max per `[AHR-<n>]` (see *Matrix
re-render bound* in Step 5).

#### Special row: UNCLASSIFIED (TRIAGE_PARTIAL handling)

When the Reviewer returns `Verdict: TRIAGE_PARTIAL` and reports a non-zero
`Unclassified:` count, every unclassified `[AHR-<n>]` appears as a row with
`Classification: UNCLASSIFIED` and the `[f] / [g] / [h]` choice set. This is the
documented handler — `TRIAGE_PARTIAL` never falls through silently.

The Reviewer-side definition of UNCLASSIFIED is in
`agents/reviewer/request-triage.md` (the verdict is `TRIAGE_PARTIAL` when at
least one `[AHR-<n>]` could not be placed against the plan, e.g. the comment
references a file that no longer exists on the feature branch).

#### Special verdict: PLAN_NOT_FOUND

When any per-repo Reviewer returns `Verdict: PLAN_NOT_FOUND`, the standard
`Outcome: FAILED` error matrix in `orchestrator-rules.md` takes precedence.
The orchestrator MUST NOT fabricate a plan path, retry with a guessed path,
or proceed to Step 4 with the remaining repos' reports. Escalate to the
human verbatim and pause the request-handling flow. The human can: rerun
`/init-workspace` if `repos-paths.md` is stale, restore the missing plan
from version control, or kill the request.

### Step 5 — Handle Human Response

Parse the human's reply into one decision per row of the Step 4 matrix. Row
actions are **not** independent — the plan file is shared mutable state, and
two row actions can read or write it. The order below is **non-negotiable**:

#### Row-action execution order

1. **All `[a] Expand scope` rows first** (batched into a single
   `MODE: plan-amendment` invocation — see the `[a]` sub-block below).
   This pins the plan file's state before any other row reads it.
2. **All `[f] Re-triage with hint` rows next** — they re-invoke the Reviewer
   against the current plan file. Running them *after* the `[a]` batch means
   the Reviewer sees the amended plan (if `[a]` was approved) or the original
   plan (if `[a]` was rejected and rolled back), but never a partial state.
3. **All `[1] / [e] / [h]→IN_SCOPE_* / [h]→DUPLICATE` rows next** — these go
   to Step 6 (Planner: Append Ad-Hoc Tasks). The plan file is final by now.
4. **All remaining rows last** — `[2] / [d] / [g] / [b] / [c] / [h]→OUT_OF_SCOPE
   / [h]→PLAN_CONFLICT` — append to `## Deferred Requests` via Read+Write.
   Order within this group doesn't matter.

#### Matrix re-render bound

`[f] Re-triage with hint` and `[a]` rejection paths can trigger a matrix
re-render (Step 4 runs again with new classifications). To prevent infinite
recursion, **the matrix re-renders at most 3 times per `[AHR-<n>]`**
(initial render = round 0; re-render = round 1, 2, 3).

##### Persistence

The counter is durable across session interruptions. The orchestrator stores
it as a dedicated `Re-renders` column on the `## Pending Requests` ledger row
(append-only, written via the Read+Write pair) at the top of the tracker:

```
## Pending Requests

| Request ID | Submitted | Source | Re-renders | Notes |
|------------|-----------|--------|------------|-------|
| [AHR-<n>]  | <YYYY-MM-DD HH:MM UTC> | <gate-2 \| gate-3 \| mid-phase> | <0..3> | <verbatim request text — single-line; multi-line uses `\n` literal> |
```

**The `Re-renders` cell is the single source of truth for the counter.**
The Notes column carries the verbatim AHR request text (used as the Summary
fallback when the row terminates via a non-task disposition). The two cells
have disjoint roles — no shadow state, no normalisation contract needed.

The row is created when the orchestrator captures the request in Step 1 and
deleted when the request reaches a terminal state (task created at Step 6 →
delete; deferred request → delete the pending row, append to
`## Deferred Requests`).

If a session is interrupted between Step 4 and Step 5, the next session reads
the `## Pending Requests` row's `Re-renders` cell to recover the counter. If
the row is missing, the counter is presumed 0 (the request is new). If the
row exists but the matrix has not been re-rendered yet, the counter is 0.

##### Increment rules

Every action that triggers a new matrix render counts as +1 against the row's
`Re-renders` cell. The complete list — refer to the *Worked example* below
for a concrete sequence:

| Trigger | Increment |
|---------|-----------|
| Initial Step 4 render after Reviewer triage | 0 (this is round 0) |
| `[f] Re-triage with hint` on the row | +1 |
| `[h] Override → OUT_OF_SCOPE` or `[h] → PLAN_CONFLICT` on the row | +1 (the row re-renders with the `[a]/[b]/[c]` choice set) |
| `[a] Expand scope` rejected at the scoped GATE #1 re-presentation | +1 (the row falls through to a new render with the original out-of-scope choice set) |
| `[a] Expand scope` approved → Reviewer re-triages the row | +1 (the row's classification changes from OUT_OF_SCOPE/PLAN_CONFLICT to IN_SCOPE_*; this is a new classification round) |

##### Bound enforcement

When an `[AHR-<n>]` reaches `Re-renders == 3` and its row would re-render
a fourth time, the orchestrator MUST:

1. Pin the row's *current* classification (the most recent Reviewer verdict).
2. Strip the `[f]` choice from the row in the next matrix render.
3. Surface a one-line note above the matrix: *"`[AHR-<n>]` has re-triaged 3
   times — the `[f]` option is no longer offered. Choose from the remaining
   options or `[SKIP-ALL]`."*

The bound is intentionally low — three re-triages is more than enough for any
reasonable human-guided clarification and prevents the matrix from livelocking
on an ambiguous request. The human can always `[SKIP-ALL]` or `[c] Withdraw`
to terminate.

##### Worked example

`[AHR-1]` is submitted at GATE #2. The Reviewer classifies it as `OUT_OF_SCOPE`.
The matrix renders with `[a]/[b]/[c]` (round 0, `Re-renders: 0`).

| Round | Human action | Re-renders after | Reasoning |
|-------|--------------|------------------|-----------|
| 0 | (initial render) | 0 | Triage just returned. |
| 1 | `[a] Expand scope` | 1 | Amendment approved → row re-triages → +1. |
| 2 | (now `IN_SCOPE_BUG`; human picks `[2] Skip`) | 1 | `[2] Skip` is terminal; no re-render. |

Counter ends at 1 of 3; the row terminates via `[2]` → `## Deferred Requests`.

A worst case for the bound:

| Round | Human action | Re-renders after | Note |
|-------|--------------|------------------|------|
| 0 | (initial render — `OUT_OF_SCOPE`) | 0 | |
| 1 | `[a]` → amendment rejected | 1 | Row falls back to `[a]/[b]/[c]`. |
| 2 | `[a]` again → second amendment rejected | 2 | Row falls back to `[a]/[b]/[c]` again. |
| 3 | `[h] Override → PLAN_CONFLICT` (different angle) | 3 | Row re-renders with `[a]/[b]/[c]` for the new classification. |
| — | (would-be 4th re-render) | — | Bound enforced; `[f]` would be stripped (already absent from this row's choice set anyway); human must terminate via `[b]`, `[c]`, or `[SKIP-ALL]`. |

Note that `[1]` / `[e] → IN_SCOPE_BUG` / `[h] → IN_SCOPE_BUG` / `[h] → IN_SCOPE_AC_MISS` / `[h] → DUPLICATE` / `[h] → INVALID` are **terminal** — they route the row to its disposition (task creation or Deferred Requests) and never re-render. Only the choices listed in the *Increment rules* table tick the counter; every other choice is +0.

#### Action handlers

The handlers below describe what happens to each row class. Apply them in the
order pinned above.

**Rows with `[1] Confirm` or `[e] Override → Confirm` or `[h] Override → IN_SCOPE_*`:**
Collect the `(repo, [AHR-<n>])` pairs. They become ad-hoc tasks at Step 6.

**Rows with `[2] Skip`, `[d] Acknowledge`, `[g] Skip` (UNCLASSIFIED), or `[h] Override → DUPLICATE / INVALID`:**
Append a row to `## Deferred Requests` with the appropriate disposition
(`ACKNOWLEDGED`). No task is created. No Planner invocation needed —
the orchestrator writes the row directly via Read+Write on the tracker.

**Summary column provenance**: when the original Reviewer verdict provided a
one-line summary (`[2]`, `[d]` on a Reviewer-classified row), the orchestrator
uses that summary. When the row was `UNCLASSIFIED` (no Reviewer summary
available) or `[h] Override → ...` was used (the Reviewer's prior summary may
not match the human's override classification), the orchestrator falls back
to **the verbatim AHR request text** captured in Step 1 — single-line; if the
request body spans multiple lines, the orchestrator joins them with `\n`
literal characters so the row remains parseable. The verbatim text is always
recoverable from the `## Pending Requests` ledger row (until it is deleted at
Step 6 / Step 7 of the disposition handler).

**Rows with `[f] Re-triage with hint`:**
Capture the human's hint. Re-invoke the relevant per-repo Reviewer in
`mode: request-triage` for that single `[AHR-<n>]` only, with the hint appended
as additional context. Re-render the Step 4 matrix with the updated row(s) and
collect a fresh response. Any other rows the human already answered remain in
place (don't ask them twice).

**Rows with `[b] Defer as new story` or `[c] Withdraw`:**
Append the row to `## Deferred Requests` with the appropriate disposition.
For `[b]`, surface a reminder to the human to open a new work item in the
configured provider — the orchestrator does NOT call the provider adapter.
No task is created.

**Rows with `[a] Expand scope` (one or more):**

1. **Snapshot the plan to disk** before invoking the amendment. Use the **Read** tool to load the current plan file's full content into the orchestrator session, then use the **Write** tool to persist a copy to:

   ```
   <WORKSPACE_ROOT>/ai/.snapshots/<plan-basename>-<YYYY-MM-DD-HHMMSS>-<uid8>.md
   ```

   - `<plan-basename>` is the plan filename without its `.md` extension.
   - The timestamp is `date -u +"%Y-%m-%d-%H%M%S"`.
   - `<uid8>` is an 8-character random identifier generated via `uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -c1-8` (with `python3 -c "import uuid; print(str(uuid.uuid4())[:8])"` as fallback — same generator the worktree-branch naming uses in `develop.md` Step 1 sub-step 5). The uid8 suffix prevents same-second filename collisions across consecutive `[a] Expand scope` flows within a single matrix re-render window — without it, two snapshots taken in the same UTC second would overwrite each other and the second rollback would lose the original-plan state.

   The orchestrator also caches the same content as `PLAN_SNAPSHOT` in session state for fast in-memory restore. **The on-disk copy is the durable rollback artifact** — it survives session crashes, API errors, and `/compact` operations that may evict the in-memory cache. The in-memory copy is just the fast path; if it's missing on restore, the on-disk copy is authoritative.

   This snapshot pair is workspace-agnostic — works whether the workspace is a git repo or a plain directory. `bash-write-guard` blocks Bash writes to `ai/` paths; the Write tool is the only approved snapshot mechanism (same constraint as the Phase 6 workspace-into-repo Read+Write pattern).
2. Invoke `@ai-sdlc-planner` with `MODE: plan-amendment` (foreground) and **every** OUT_OF_SCOPE / PLAN_CONFLICT row the human picked `[a]` for — batch them into a single amendment invocation so the plan grows by one `## Plan Amendment — Ad-Hoc Round <N>` section per batch, not per row. The Planner appends the section to the plan file.
3. Re-present GATE #1 (plan approval) scoped to the amendment delta only — show the human the appended section (and only that section), and request approval.
4. **On approval**: commit the plan if the workspace is a git repo (otherwise leave the amended plan in `<WORKSPACE_ROOT>/ai/plans/` per orchestrator rule #8). **Delete the on-disk snapshot** at `<WORKSPACE_ROOT>/ai/.snapshots/<plan-basename>-<timestamp>-<uid8>.md` — it is no longer needed. The orchestrator must remember the exact filename it just wrote (timestamp + uid8) to avoid deleting an unrelated snapshot from a concurrent amendment flow. Re-invoke the Reviewer in `mode: request-triage` for the same request — under the amended plan it should now classify as `IN_SCOPE_AC_MISS` (or, if the amendment changed how the request maps to existing tasks, `IN_SCOPE_BUG` or `DUPLICATE`). Continue with Step 6 for the re-triaged classification.
5. **On rejection** (the human declines the amendment, e.g. by replying `CHANGES <description>` or `WITHDRAW`): **restore the plan**. Prefer the in-memory `PLAN_SNAPSHOT` cache (fast path). If `PLAN_SNAPSHOT` is unavailable (session was resumed after a crash and the cache was evicted), Read the on-disk snapshot at the exact `<plan-basename>-<timestamp>-<uid8>.md` path the orchestrator wrote in step 1 instead. Use the Write tool to overwrite the plan file with the restored content. After restore, delete the on-disk snapshot. Then fall through to the human's revised choice — typically `[b] Defer as new story` or `[c] Withdraw` for the original request, recorded in `## Deferred Requests`. Do not silently keep the rejected amendment in the plan file.
6. **On a partial revision** (the human asks for the amendment to be reworked rather than accepted or rejected): re-invoke the Planner with `MODE: plan-amendment` and the human's revision instructions. The Planner edits the appended section in place (the snapshot's role is unchanged — restore on a final rejection, delete on a final approval). The on-disk snapshot is **not** updated during revisions — it always points at the pre-amendment state.

The `bash-write-guard` hook blocks Bash writes to `/ai/` paths by design, so the rollback in step 5 MUST go through the Write tool — not `cp`, `mv`, or `>`. The Read+Write pair is the canonical pattern for both this restore and for the workspace-into-repo file moves in Phase 6.

**Global option `[SKIP-ALL]`:**
Every row not answered individually is recorded in `## Deferred Requests` with disposition `ACKNOWLEDGED`. No tasks are created. Proceed to Step 8 (Return to the Previous Gate) — Step 6 is skipped because nothing was confirmed.

### Step 6 — Planner: Append Ad-Hoc Tasks to Tracker

For each confirmed in-scope `[AHR-<n>]`, invoke `@ai-sdlc-planner` with `MODE: ad-hoc-tasks` (foreground). The Planner's behaviour for this mode is documented in `skills/plan-generator/SKILL.md` under **Ad-Hoc Task Mode** — the prompt below provides the orchestrator-side context (paths, story ID, accepted requests, batch number); the skill owns the row template, separate-table heading, and dependency-graph regeneration.

```
@ai-sdlc-planner Append ad-hoc tasks to the existing tracker for Story $ARGUMENTS.

MODE: ad-hoc-tasks

CONTEXT:
- Tracker path: <ai/tasks/<existing-tracker-filename>>
- Plan path: <ai/plans/<existing-plan-filename>>
- Story ID: #<STORY-ID>
- Batch: <N>   # 1 on the first Ad-Hoc invocation for this story, 2 on the second batch,
               # etc. Derived by the orchestrator from the count of existing
               # `## Ad-hoc Tasks (Batch …)` headings in the tracker, plus one.
- Submission source: <gate-2 | gate-3 | mid-phase>
- Submission timestamp: <date -u +"%Y-%m-%d %H:%M UTC">

CONFIRMED IN-SCOPE REQUESTS:
[AHR-<n>] Repo: <repo-name> | Classification: <IN_SCOPE_BUG | IN_SCOPE_AC_MISS>
Reviewer reasoning: <from triage report>
Proposed task: <one-sentence description from Reviewer>
Affected files: <list from Reviewer>

[AHR-<m>] ...

Instructions:
1. Read the existing tracker and plan.
2. Identify the highest existing Task ID across the main table, prior amendments,
   and prior ad-hoc batches (e.g. if last task is T8, next is T9).
3. For EACH confirmed AHR, append one new task row under a new
   `## Ad-hoc Tasks (Batch <N>)` heading below any existing amendments/ad-hoc tables.
4. Add a Test Outline section for each new task to the PLAN document under a new
   `## Test Outline — Ad-Hoc Batch <N>` heading, following the Subject_Scenario_Outcome
   convention. `test-required: false` is allowed for pure-config fixes — justify in the
   plan.
5. Regenerate the tracker's `## Dependency Graph` to include the new tasks (root nodes
   flowing into the existing T-TEST-<RepoName> node for their repo, per the rendering
   rules in plan-generator/SKILL.md).
6. Record `Ad-hoc requests started` (Workflow Metrics) if this is the first batch;
   otherwise leave the metric in place.
7. Save the updated tracker and plan files. Verify each by reading them back.
```

Parse the Planner's `📋 AGENT STATUS`. If `Outcome: PARTIAL` or `FAILED`, follow the error handling rules in `orchestrator-rules.md`.

After confirmed `Outcome: SUCCESS`, record `Ad-hoc requests started` in orchestrator state (only if not already set this story).

### Step 7 — Re-Enter TDD Development Loop

Read and execute `commands/develop.md`, applying this scope filter before starting:

> **Only process tasks whose row lives under a `## Ad-hoc Tasks (Batch …)` heading and whose Status is ⏳ Pending.**

All Phase 3 rules apply unchanged:
- TDD path for `test-required: true` tasks (Tester → Developer → Reviewer)
- Direct path for `test-required: false` tasks (Developer → Reviewer)
- Worktree isolation per task
- Sequential execution within each repo
- Parallel execution across repos (via `run_in_background: true`)
- Squash-merge on Reviewer approval

After all ad-hoc tasks are ✅ Done across all repos, proceed to Step 7b.

### Step 7b — Re-trigger Phase 5 hardening on affected repos (post-Phase-5 batches only)

Ad-hoc batches landing **after** Phase 5 has already completed (typically
`source: gate-3` or a `source: mid-phase` request submitted after Phase 5
finished) introduce new production code that has never been checked against
the 90% coverage gate. Without this step, the new code ships in the PR
without coverage enforcement — same gap as the Phase 7 amendment case (see
`commands/review-response.md` Step 8b for the full rationale; both paths
reuse the existing `T-TEST-<RepoName>` row).

For each repo where this ad-hoc batch added at least one task, read the
`T-TEST-<RepoName>` row's Status:

- **`Status: ✅ Done`** → re-trigger Phase 5 hardening on this repo:
  1. Set `T-TEST-<RepoName>` → `🔧 In Progress` (legal `✅ Done → 🔧 In Progress`
     transition per `tracker-schema.md`). Per the universal orchestrator rule
     "Set task `Started` (Task Metrics) when marking a task 🔧 In Progress"
     (`orchestrator-rules.md` → rule #3), this **also overwrites the original
     Phase 5 `Started` timestamp** on the T-TEST row. Both `Started` and
     `Completed` end up reflecting the most recent hardening pass; the audit
     trail of "when did the first Phase 5 run start" lives in
     `Test hardening started` in the Workflow Metrics table (not re-stamped by
     this step).
  2. Invoke `commands/test.md` Step 1 (auto-harden Tester) and Step 2 (Reviewer)
     for this repo, following the exact same loop as the original Phase 5 run.
  3. On Reviewer `APPROVED` → set `T-TEST-<RepoName>` → `✅ Done`, set
     `Reviewer Verdict` to ✅ Approved, set `Completed` in Task Metrics to the
     current UTC timestamp.
  4. On Reviewer `CHANGES_REQUESTED` → loop per the standard Phase 5 handling.

- **`Status` is anything else** → Phase 5 has not yet completed for this repo
  (e.g. a `source: gate-2` batch that landed before Phase 5, or a `source: mid-phase`
  batch that arrived mid-Phase-5 for a repo whose hardening is still in flight).
  The upcoming or in-flight Phase 5 run will naturally include the ad-hoc code
  in its coverage scope. Skip the re-trigger.

This step is a no-op for `source: gate-2` batches (Phase 5 hasn't run yet — the
`Status: ✅ Done` branch is never reached) and fires for `gate-3` / post-Phase-5
`mid-phase` batches as described above. The source-agnostic check on T-TEST
status is the durable signal; the `source:` token in the Notes column is
audit-only and is not consulted here.

Multiple repos may be re-triggered in parallel via `run_in_background: true`
per the standard Phase 5 parallel-hardening pattern.

After every re-triggered `T-TEST-<RepoName>` returns to ✅ Done, proceed to Step 8.

### Step 8 — Return to the Previous Gate

Set `Ad-hoc requests completed` (Workflow Metrics) to `date -u +"%Y-%m-%d %H:%M UTC"`.

Resume the gate the request batch interrupted:

- **Source `gate-2`**: re-present GATE #2 (`commands/approve-impl.md`). The Per-Repo summary now reflects the additional ad-hoc task commits.
- **Source `gate-3`**: re-run Step 2 (Pre-PR Holistic Review) of `commands/create-pr.md` so the Reviewer sees the new commits, then re-present GATE #3 with the updated report.
- **Source `mid-phase`**: **re-scan lane state, do not assume the previous lane is still active.** While Steps 2–6 ran, any in-flight background agent's completion notification was deferred (see the *Concurrency model* in the Usage section). By the time Step 8 runs, those notifications are queued at the loop layer and the affected lane may have already completed its task and exited. The orchestrator MUST:
  1. Process any deferred completion notifications first (in `develop.md` Step 2 order).
  2. Re-read the tracker to determine which lanes have ⏳ Pending rows remaining (now including the new ad-hoc rows just appended).
  3. Re-enter `develop.md` Step 1 to pick up the next pending task per lane, exactly as if the orchestrator had been resumed from a fresh session. Do NOT assume any specific lane is mid-task — if a lane is idle, it will pick up either a pending main-table row or a newly-appended ad-hoc row in tracker order; if a lane is still mid-task (its agent has not yet completed), its current task continues to completion before the next pop.

  This guarantees correctness whether the lane that triggered the request is still running, has just completed, or has exited entirely.

## Tracker Schema — Ad-Hoc Tasks and Deferred Requests

Two new sections are appended below the main task table. Both are owned by the Planner (`MODE: ad-hoc-tasks`) and the orchestrator updates Status / Reviewer Verdict / Commit(s) per the standard transitions.

```markdown
## Ad-hoc Tasks (Batch <N>)

| Task ID | Repo | Title | Status | Reviewer Verdict | Commit(s) | Notes |
|---------|------|-------|--------|------------------|-----------|-------|
| T<next-n> | <repo-name> | <≤ 60-char title> | ⏳ Pending | — | — | ad-hoc: [AHR-<n>] · source: <gate-2 \| gate-3 \| mid-phase> · submitted: <YYYY-MM-DD HH:MM UTC> · test-required: <true \| false> |

## Deferred Requests

| Request ID | Submitted | Source | Classification | Disposition | Summary |
|------------|-----------|--------|----------------|-------------|---------|
| [AHR-<n>] | <YYYY-MM-DD HH:MM UTC> | <gate-2 \| gate-3 \| mid-phase> | <OUT_OF_SCOPE \| PLAN_CONFLICT \| INVALID \| DUPLICATE> | <DEFERRED_AS_NEW_STORY \| WITHDRAWN \| ACKNOWLEDGED> | <one-line text> |
```

The `Notes` token `ad-hoc: [AHR-<n>]` is the canonical provenance marker — the Phase 3 re-entry filter and the orchestrator's batch-counter both rely on it. Do not rename it.

## Workflow Metrics — New Fields

Two metrics are added to the Workflow Metrics table (appended on first ad-hoc batch; the Planner adds them if missing):

| Metric | Value |
|--------|-------|
| **Ad-hoc requests started** | <first ad-hoc batch submission timestamp> |
| **Ad-hoc requests completed** | <last ad-hoc batch completion timestamp> |

These are cumulative across batches — `started` is set once at the first batch; `completed` is updated each time the orchestrator drains the queue. They are informational; they do not gate phase transitions.

## Re-Entry

This command can be invoked multiple times for the same story (e.g. a fresh batch of requests at GATE #3 after an earlier batch handled at GATE #2). Each invocation creates a new `## Ad-hoc Tasks (Batch <N>)` heading; prior batches remain Done and are not re-processed. The `[AHR-<n>]` counter is globally monotonic across the story.

## Single-Repo Backward Compatibility

If only one repo is affected, this behaves identically — one Reviewer triage, one human gate, one Planner invocation, one sequential dev loop. The merged-summary block in Step 3 still renders (with one repo).

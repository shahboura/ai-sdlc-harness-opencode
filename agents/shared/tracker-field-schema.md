# Tracker Field Schema

> Owner: cross-cutting
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-10]
     Reason: Canonical tracker field names + format strings — consumed by P9 metrics-collector + every agent reading the tracker.
     CC conventions applied: CC-04.2, CC-04.4 -->

## Purpose

Canonical schema for `tracker.md` — declares every header field, metric-block stamp, and per-task row column with its format string. Per CC-05.2 phases communicate via artifacts only; `tracker.md` is the single most-read artifact, so its field vocabulary must be authoritative and immutable.

## Tracker header fields

| Field | Format | Set by | Purpose |
|---|---|---|---|
| `Story:` | `<safe-id>` | P1 ingest | Provider work-item ID after `safe_id()` |
| `Title:` | free-text | P1 ingest | Human-readable story title |
| `Story-State:` | `Pending \| In Progress \| Done \| Archived \| Aborted` | per `tracker-transition-rules.md` | Overall story status |
| `Coverage Threshold:` | `<int>%` | P0 default; per-story override | Per CC-09 default 90; override requires reviewer sign-off |
| `Max Review Rounds:` | `<int>` | P0 default; per-story override | Per CC-09 default 5 |
| `Max Build Retries:` | `<int>` | P0 default; per-story override | Per CC-09 default 3 |
| `Hotfix-Of:` | `<parent-story-id>` *(optional)* | P0 hotfix entry | Set only by M-19 `/dev-workflow hotfix` |
| `Workflow-Dir:` | `ai/<YYYY-MM-DD>-<id>/` | P1 ingest | Canonical per-workflow directory (per CC-05.7) |

## Metric stamps (timestamp lines)

Every metric stamp uses the canonical UTC format from `skills/dev-workflow/context/timestamp.md` (`YYYY-MM-DD HH:MM UTC`). Stamps live in a `## Metrics` block at the bottom of `tracker.md`.

| Stamp | Emitter | Phase |
|---|---|---|
| `Bootstrap completed <ts>` | `init-workspace` | P0 |
| `Plan approved <ts>` | `plan-generator` post-GATE #1 | P2 |
| `Development started <ts>` | `develop` Step 0 | P3 |
| `Task Started <ts> — T<n>` | `develop` per-task | P3 |
| `Task Completed <ts> — T<n>` | `develop` per-task | P3 |
| `Initial development completed <ts>` | `develop` final | P3 |
| `Human approval (impl) <ts>` | `approve-impl` post-GATE #2 | P4 |
| `Test hardening completed <ts>` | `test` Step 6 | P5 |
| `Security review completed <ts>` | `security-review` Step 6 | P5.5 |
| `Gate #2.5 <waive\|fix-now\|defer> <ts>` | `security-review` (gate decision) | P5.5 |
| `Gate prompted <ts> — <gate-id>` | `_tracker_metrics_guard.py` | per-gate |
| `PR created <ts>` | `create-pr` Step 9 | P6 |
| `PR review response completed <ts>` | `review-response` Step 9 | P7 |
| `Ad-hoc requests started <ts>` | `handle-request` Step 6 (first batch only) | IG |
| `Ad-hoc requests completed <ts>` | `handle-request` (final batch close) | IG |
| `Merge detected <ts>` | `reconcile` | P8 |
| `Workflow completed <ts>` | `reconcile` final | P8 |
| `Workflow aborted <ts> — <cause>` | R | R |
| `Recovery started <ts>` | `resume` | R |
| `Metrics collected <ts>` | `metrics-collector` | P9 |
| `Lane <repo>: started <ts>` | per-lane | P3/P5/P5.5/P6/P7/IG |
| `Lane <repo>: completed <ts>` *(or `failed <ts>`)* | per-lane | P3/P5/P5.5/P6/P7/IG |
| `Re-entered P3 for tasks <list> at <ts>` | `phase-re-entry.md` consumer | P7/IG |

## Per-task row schema

Tasks live in a `## Tasks` table at the top of `tracker.md`. Each row:

| Column | Format | Notes |
|---|---|---|
| `Task` | `T<n>` | 1-based |
| `Description` | free-text | one-line from plan |
| `Repo` | `<safe-id>` | which repo the task touches |
| `Status` | per `tracker-transition-rules.md` | FSM-controlled |
| `T-TEST` | `ABSENT \| PARTIAL \| COVERED` | per `phase-re-entry.md` |
| `Reviewer-Verdict` | `APPROVED \| CHANGES_REQUESTED \| IN_REVIEW \| —` | per `status-schema.md` |
| `Build` | `PASS \| FAIL \| NOT_RUN \| —` | per task |
| `Review-Rounds` | `<int>` | bounded by CC-09 |
| `Build-Retries` | `<int>` | bounded by CC-09 |
| `Commit(s)` | comma-separated SHAs or `—` | populated by the orchestrator per-task; rewritten after Phase 6 autosquash |
| `Notes` | structured token stream (NOT freeform) | tokens joined by ` · `; vocabulary in [`plan-generator/tracker-schema.md`](../../skills/plan-generator/tracker-schema.md) → *Notes column tokens* |

### Notes column — stable contract

The `Notes` column carries machine-readable tokens, not freeform prose. Consumers parse them — adding ad-hoc text, reformatting whitespace, or renaming tokens breaks the parsers. The canonical token vocabulary, separator (` · ` / Unicode middle dot), and per-section validity (Main / Amendments / Ad-hoc) live in [`skills/plan-generator/tracker-schema.md`](../../skills/plan-generator/tracker-schema.md) → *Notes column tokens*. Notable contracts pinned there:

- `test-required: <true | false>` — Phase 3 TDD switch.
- `depends: T<a>[, T<b>...]` — intra-repo dependency gate.
- `[API: <lib> v<version>]` — Developer's API-compat precondition.
- `PR-comment: [PC-<n>] thread_id=<id>` — Phase 7 amendment ↔ PR-comment-thread link. The `thread_id=<id>` substring is the contract write by `plan-generator` (Step 7) and read by `review-response.md` (Step 9 reply path). Reformatters MUST preserve the literal `thread_id=<id>` token verbatim — splitting it across token boundaries, quoting `<id>`, or renaming `thread_id` to `threadID` / `thread-id` breaks the round-trip.
- `ad-hoc: [AHR-<n>]` — ad-hoc request provenance.

A row with a Notes cell that fails to parse against the vocabulary above is a workflow-failure surface, not a tolerated warning: `_tracker_*.py` consumers refuse to advance the lane until the cell is repaired.

> **Vocabulary boundary**: `IN_REVIEW` is a **Reviewer-Verdict** sentinel (per `status-schema.md`) — distinct from the per-task `🔄 In Review` Status value enforced by the tracker-transition-guard. The task-row Status FSM has 5 states (`⏳ Pending`, `🔧 In Progress`, `🔄 In Review`, `✅ Done`, `📦 Archived`) and is owned by [`tracker-transition-rules.md`](tracker-transition-rules.md). The `Story-State:` header field is a separate enum (`Pending | In Progress | Done | Archived | Aborted`) that records the workflow's overall position — see the same file for the linear transitions.

## `test-required` + `Why-no-test:` enumeration (M-20 IMPL-20-02)

<!-- Added: dev-workflow-plan.md [M-20] [IMPL-20-02]
     Reason: RAG-31 — close the loophole where a planner could set every task
     `test-required: false` and reduce the workflow to test-after-the-fact.
     CC conventions applied: CC-01.4 (planner output schema), CC-08.4 (acceptable variance). -->

Every behavioural task in the plan carries a `test-required` flag. Per M-20 the **default is `true`** — `_tdd_red_verify.py` enforces a genuine red→green test transition on every impl commit. To set `test-required: false`, the planner MUST supply a `Why-no-test:` reason drawn from the enumerated set below. The Convention-Check (TEST-128) rejects `test-required: false` without a justification.

| `Why-no-test:` value | Meaning |
|---|---|
| `doc-only` | The task changes only `.md` / docs / comments; no behavioural change. |
| `config-only` | The task changes only configuration values (env vars, language-config thresholds, etc.) — no executable code path is added or modified. |
| `trivial-typo` | Single-character fix in a literal string or comment; no behaviour change. |
| `pure-rename` | Symbol rename only; existing tests still cover behaviour. |
| `infra-only` | Change to build / CI / pipeline files with no production-code behaviour change. |

Any other reason is rejected; the planner must split the task into a test-required portion and a separately-justified non-behavioural portion.

## Cross-cutting fields (not per-task)

| Field | Format | Set by |
|---|---|---|
| `worktree_failed: true` | literal | `worktree-lifecycle.md` consumer on failure |
| `Recovery-State:` *(optional)* | per `recovery-protocol.md` | R |
| `mermaid-validated:` | `true \| false` | M-16 validator |

## Consumers

| Consumer | Reads | Writes |
|---|---|---|
| `_tracker_metrics_guard.py` | every metric stamp | `Gate prompted <ts>` |
| `_tracker_transition_guard.py` | `Status` column | (enforces FSM, no writes) |
| `metrics-collector` (P9) | every metric stamp | reads-only |
| `workflow-status` | every field | reads-only |
| every agent | their own fields | their own fields |

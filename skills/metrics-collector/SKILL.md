---
name: metrics-collector
description: >
  Pure aggregator for workflow metrics. Reads timestamp stamps from a tracker
  and produces `metrics-report.md` (per-workflow) plus appends one row to
  workspace-level `ai/_metrics-log.csv`. No agent reasoning — deterministic
  data aggregation only.
version: 1.0
inputs:
  - name: workflow_dir
    type: arg
    description: Per-workflow directory under `ai/<YYYY-MM-DD>-<work-item-id>/`.
  - name: round
    type: arg
    description: Round label (`0` for PR creation, `1..N` for review cycles, `final` for post-merge reconciliation).
outputs:
  - name: metrics-report.md
    destination: <workflow_dir>/metrics-report.md
    description: Per-workflow aggregated metrics report (CC-05.7 path).
  - name: _metrics-log.csv
    destination: ai/_metrics-log.csv
    description: Append-only workspace-level CSV keyed `(work_item_id, round)`.
phase: 9
owner_role: orchestrator
---

# /metrics-collector — Workflow Metrics Aggregator

<!-- Created by: dev-workflow-plan.md [M-17] [IMPL-17-02..04]
     Reason: NEW P9 phase per GAP-24 — deterministic metrics aggregation triggered post-PR (T1),
     post-review (T2), and post-reconcile (T3).
     CC conventions applied: CC-01.1, CC-01.4, CC-01.5, CC-01.7, CC-04.3, CC-05.7. -->

## Purpose

Pure data aggregator over a single per-workflow tracker. Reads timestamp stamps from the tracker's Metrics block + the per-task Task Metrics rows, computes the six required workflow aggregates, and writes them to `metrics-report.md` (per-workflow) and `ai/_metrics-log.csv` (workspace-level append-only log).

**No agent reasoning** — the skill never invokes an LLM. It is invoked by the orchestrator as a pure subprocess.

## When to use

- **T1 trigger** — from `commands/create-pr.md` final step, with `--round 0` (PR creation timestamp captured).
- **T2 trigger** — from `commands/review-response.md` end of each cycle, with `--round <n>` (1-indexed review round).
- **T3 trigger** — from `commands/reconcile.md` after archive, with `--round final` (terminal row).
- **Manual** — `/dev-workflow metrics <work-item-id> [--round <n>|final]` for ad-hoc backfill.

## Preconditions

- The per-workflow directory `ai/<YYYY-MM-DD>-<work-item-id>/` exists and contains a tracker (`tracker.md` or `tracker.archived.md` post-T3).
- The tracker carries a `## Metrics` block with the expected stamps per [tracker-field-schema](../../agents/shared/tracker-field-schema.md).
- Tracker timestamps are well-formed `YYYY-MM-DD HH:MM UTC` strings.

## Inputs

| Name | Type | Description |
|---|---|---|
| `workflow_dir` | arg | Path to the per-workflow dir per [workflow-paths](../dev-workflow/context/workflow-paths.md). |
| `round` | arg | `0` (PR creation) / `1..N` (review cycle) / `final` (reconcile). |

## Steps

> Authoritative references: [timestamp](../dev-workflow/context/timestamp.md), [workflow-paths](../dev-workflow/context/workflow-paths.md), [tracker-field-schema](../../agents/shared/tracker-field-schema.md), [tracker-transition-rules](../../agents/shared/tracker-transition-rules.md)

1. **Resolve paths**. From `workflow_dir`, locate `tracker.md` (or `tracker.archived.md`). Refuse with exit 2 if neither exists.
2. **Parse Metrics block**. Extract every timestamp stamp keyed by metric label (`Plan approved`, `Development started`, `PR created`, etc.) using the canonical field names from `tracker-field-schema.md`. Pre-2.0 trackers may still carry the legacy names (`Approved-Impl`, `PR-Opened`, `Comments resolved`, `Test-hardening completed`); the collector accepts both shapes.
3. **Validate ordering**. Per CC-01.5, if a `Completed` stamp precedes its `Started` counterpart for the same task, refuse with exit 1 + `.error.md` describing the inconsistency. **Do not append to the CSV** on validation failure.
4. **Compute aggregates** (the six required outputs):
   - **Cycle time** — `PR created` − `Plan approved` (legacy `PR-Opened` accepted for old trackers).
   - **Per-phase duration** — for each phase boundary (P2 → P3 → P4 → P5 → P6 → P7 → P8), the elapsed time between adjacent stamps.
   - **Reviewer rework rounds** — per-task `Review Rounds` summed.
   - **Coverage delta** — per-repo `Coverage` final value (from P5 hardening output) vs. pre-existing baseline (if available).
   - **PR review rounds** — count of `pr-comment-analysis-report-<n>.md` files in the workflow dir.
   - **Defect escape** — number of `[S<n>]` comments in any `pr-comment-analysis-report-*.md` file that route to source-code changes (vs. test-coverage gaps).
5. **Write `metrics-report.md`** at `<workflow_dir>/metrics-report.md` (CC-05.7 path).
6. **Append one row to `ai/_metrics-log.csv`** with the schema below.
7. **Stamp the tracker** with `Metrics collected <ts> — round <n>` using the canonical UTC timestamp.
8. **Exit 0** on success.

## `ai/_metrics-log.csv` schema (IMPL-17-04, IMPL-25-03)

<!-- Updated by: dev-workflow-plan.md [M-25] [IMPL-25-03]
     Reason: v1.1.0 schema adds token-usage columns (ADR-002 orchestrator capture)
     and mode column (FR-1.7 quick|full marker).
     CC conventions applied: CC-02.4.2 (null-safe token fields), CC-04.6. -->

| Column | Added | Required | Notes |
|---|---|---|---|
| `schema_version` | v1.0.0 | ✅ | Current `1.1.0`. First column — drives mixed-version reads. |
| `work_item_id` | v1.0.0 | ✅ | Post-`safe_id()` story identifier. |
| `round` | v1.0.0 | ✅ | `0` / `1..N` / `final`. |
| `timestamp_utc` | v1.0.0 | ✅ | Row write time. |
| `cycle_time_minutes` | v1.0.0 | ✅ | Minutes between `Plan approved` and `PR created`. |
| `p3_duration_minutes` | v1.0.0 | ✅ | Phase 3 development duration. |
| `p5_duration_minutes` | v1.0.0 | ✅ | Phase 5 test-hardening duration. |
| `p7_duration_minutes` | v1.0.0 | optional | Phase 7 review-response duration (per round). |
| `reviewer_rework_rounds` | v1.0.0 | ✅ | Aggregated `Review Rounds` across tasks. |
| `pr_review_rounds` | v1.0.0 | ✅ | Count of P7 cycles. |
| `coverage_pct` | v1.0.0 | ✅ | Final per-story coverage. |
| `defect_escape_count` | v1.0.0 | ✅ | `[S<n>]` source-code comments. |
| `tokens_input` | **v1.1.0** | optional | Input tokens for this story (ADR-002). Empty until `metrics-token-collector.sh` lands (US-E02-003). Render as "tokens unavailable" not `0` when empty. |
| `tokens_output` | **v1.1.0** | optional | Output tokens. Same null policy as `tokens_input`. |
| `tokens_cache_read` | **v1.1.0** | optional | Cache read tokens. Same null policy. |
| `tokens_cache_write` | **v1.1.0** | optional | Cache write tokens. Same null policy. |
| `mode` | **v1.1.0** | ✅ | Workflow mode: `quick` or `full` (FR-1.7). Default `full` for pre-v2.1 trackers. |

**Schema evolution policy** (CC-04.6): bump minor when adding columns; bump major + ship a migration script when removing columns. Older rows keep their original `schema_version` ("1.0.0") — downstream BI handles mixed-version reads. The collector auto-migrates v1.0.0 files to v1.1.0 on the first v1.1.0 append (idempotent).

## Outputs

| Destination | Content |
|---|---|
| `<workflow_dir>/metrics-report.md` | Per-workflow aggregated report (markdown). |
| `ai/_metrics-log.csv` | Append-only workspace-level log; one row per invocation. |
| Tracker Metrics block | `Metrics collected <ts> — round <n>` stamp. |
| Exit code | 0 (success) / 1 (validation failure — bad timestamps) / 2 (precondition unmet). |

## Exit criteria

- `metrics-report.md` exists at the canonical path.
- One new row in `ai/_metrics-log.csv` (or the lock guarded retry path completed cleanly).
- Tracker carries the `Metrics collected <ts> — round <n>` stamp.

## Failure modes

| Failure | Detection | Response |
|---|---|---|
| Tracker missing | Step 1 path resolution | Exit 2 with `.error.md`. |
| Timestamp inconsistency | Step 3 ordering check | Exit 1; emit `.error.md` describing the bad pair; **do not append** to CSV. |
| CSV lock contention | Step 6 file-lock acquisition | Retry once (1s); on second failure emit `.error.md` and exit 1. |
| Coverage data missing | Step 4 coverage extraction | Best-effort: leave `coverage_pct` empty; surface advisory; do not block. |

## Related skills

- `commands/metrics.md` — orchestrator entry point that invokes this skill.
- `coverage-report` — produces the per-repo coverage values that this skill aggregates.

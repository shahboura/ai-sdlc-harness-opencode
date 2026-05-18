# Phase 9: Metrics & Observability

> Authoritative references: [timestamp](../context/timestamp.md), [workflow-paths](../context/workflow-paths.md), [tracker-field-schema](../../../agents/shared/tracker-field-schema.md)

<!-- Created by: dev-workflow-plan.md [M-17] [IMPL-17-05]
     Reason: NEW P9 phase per GAP-24 — orchestrator-side entry point that invokes the
     metrics-collector skill at the three trigger points (T1 PR creation, T2 review cycle, T3 reconcile).
     CC conventions applied: CC-05.1, CC-07.3, CC-04.3. -->

**Phase**: 9
**Actor**: Orchestrator only (invokes the `metrics-collector` skill — no agents)

## Trigger

One of:

1. **T1** — Automatically from `commands/create-pr.md` final step, with `--round 0`.
2. **T2** — Automatically from `commands/review-response.md` end of each review cycle, with `--round <n>`.
3. **T3** — Automatically from `commands/reconcile.md` after archive, with `--round final`.
4. **Manual** — `/dev-workflow metrics <work-item-id> [--round <n>|final]` for ad-hoc backfill.

## Preconditions

- Per-workflow directory `ai/<YYYY-MM-DD>-<work-item-id>/` exists.
- Tracker carries the metrics stamps required for the requested aggregates (e.g. `Plan approved` and `PR created` for cycle time).

## Steps

### S1 — Resolve the workflow directory

Resolve from the `<work-item-id>` arg via `safe_id()` glob `ai/*-<safe-id>/`. Per CC-05.7.2 there is exactly one such directory per story.

### S2 — Invoke the metrics-collector skill

```
/metrics-collector <workflow_dir> --round <round>
```

The skill is pure data-aggregation (no agent reasoning) — see [metrics-collector](../../metrics-collector/SKILL.md).

### S3 — Stamp the tracker

Append `Metrics collected <ts> — round <round>` to the tracker's `## Metrics` block using the canonical UTC timestamp ([timestamp](../context/timestamp.md)).

### S4 — Surface aggregate to human (optional)

On manual invocation only, render the resulting `metrics-report.md` inline to the human. On automatic T1/T2/T3 triggers, do NOT inline — the report lives on disk for later consumption.

## Outputs

| Artifact | Path | Format |
|---|---|---|
| `metrics-report.md` | `ai/<workflow_dir>/metrics-report.md` | Per-workflow aggregated report. |
| `ai/_metrics-log.csv` | `ai/_metrics-log.csv` | Append-only workspace-level log. |
| Tracker stamp | Tracker `## Metrics` block | `Metrics collected <ts> — round <n>`. |

## Exit Criteria

1. metrics-collector returns exit 0.
2. `metrics-report.md` exists at the canonical path.
3. Tracker carries the metrics stamp.
4. New row appended to `_metrics-log.csv`.

## Failure Modes

| Failure | Detection | Response |
|---|---|---|
| Tracker timestamp inconsistency | metrics-collector exit 1 | Surface `.error.md` to human; do not append CSV. |
| Workflow directory missing | safe-id glob returns nothing | Exit 2 with `Reason: no workflow dir for <id>`. |
| CSV lock contention | metrics-collector retry exhausted | Surface `.error.md`; the orchestrator may retry after a short delay. |

## CC Conventions Applied

- CC-05.1 — Phase contract.
- CC-05.3 — Explicit exit signal via `Metrics collected <ts>` stamp.
- CC-07.3 — Canonical-spec header (top of file).
- CC-04.3 — All shared snippets cited; no inline reproduction.

## Next Phase

Workflow Complete (this is the terminal phase per CC-05). When invoked manually on an archived workflow, the operation is read-only — no next phase.

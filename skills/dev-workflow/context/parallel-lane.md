# Parallel Lane Lifecycle

> Owner: cross-cutting
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-17]
     Reason: Foundational shared snippet — declares the fan-out lane lifecycle reused by P3, P5, P5.5, P6, P7, IG (Finding 2.1 from 2026-05-17 audit).
     CC conventions applied: CC-04.2, CC-04.4, CC-05.6, CC-08.5 -->

## Purpose

Single source for the per-repo (or per-task) parallel-lane lifecycle. Per CC-05.6, every fan-out phase declares its fan-out key, per-lane sequencing rules, cross-lane sync points, and aggregation rule. This file declares the cross-cutting parts so each phase spec only declares its phase-specific fan-out key.

## Lane-spawn invariants

When a phase fans out across N repos (or N tasks):

1. **One lane per fan-out key.** Two lanes never share a worktree, branch, or tracker row.
2. **`run_in_background: true`** when the agent SDK supports it — lanes execute concurrently in independent agent sub-processes.
3. **Per-lane worktree** per `worktree-lifecycle.md`. The orchestrator passes the worktree path to the lane agent as context.
4. **Per-lane tracker scoping.** Each lane writes to a per-lane section of `tracker.md` keyed by the fan-out key — never to a shared section.

## Per-lane status aggregation

Every lane emits a final `📋 AGENT STATUS` block (per `agent-response.md`). The orchestrator collects these per-lane blocks and writes a per-lane row to the tracker:

```
Lane <repo>: <Outcome> | <Tests Green / Total> | <Coverage %> | <Build PASS/FAIL>
```

The aggregation is **synchronous** at the sync point — the orchestrator does not advance until every lane has reported.

## Cross-lane sync points

Sync points are phase-specific but follow a uniform pattern:

| Phase | Sync point | Aggregation rule |
|---|---|---|
| P3 | After every per-task lane reports | All lanes must be SUCCESS for the phase to exit |
| P5 | After every per-repo test-harden lane reports | Coverage gate per CC-09 must pass per lane; aggregate published in `summary-render.md` |
| P5.5 | After every per-repo security lane reports | Aggregate severity gate per CC-09 must pass per lane |
| P6 | After every per-repo PR-creation lane reports | Cross-repo PR contract reconciliation (every linked PR exists) |
| P7 | After every routed comment is handled | All comments resolved or escalated |
| IG | After every per-request lane reports | All requests handled |

## Per-lane failure rollup

If a single lane fails:

1. The lane writes `Outcome: BLOCKED` (or `FAILED`) with `Blockers: <cause>`.
2. The orchestrator marks the lane's tracker row with `failed: true`.
3. **Other lanes continue to completion** — failures do not preempt sibling lanes.
4. At the sync point, the phase fails (aggregation rule rejects partial success).
5. Per CC-05.7 the phase writes a per-repo error artifact at `ai/<workflow>/<phase>-error-<repo>.md` with the cause.

This **fail-soft per lane, fail-closed at sync** rule is required so partial work is recoverable.

## Lane metric stamps

Each lane emits two metric stamps to the tracker, using `timestamp.md`:

```
Lane <repo>: started <ts>
Lane <repo>: completed <ts>     # OR
Lane <repo>: failed <ts> — <one-line cause>
```

`failed` and `completed` are mutually exclusive — a lane stamps one and only one terminal stamp.

## Consumers

| Phase | Fan-out key |
|---|---|
| P3 | `task_id` (per task within a repo, possibly cross-repo) |
| P5 | `repo` (per-repo test hardening) |
| P5.5 | `repo` (per-repo SAST scan) |
| P6 | `repo` (per-repo PR creation) |
| P7 | `comment_id` (per routed comment) |
| IG | `request_id` (per routed request) |

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [parallel-lane](../context/parallel-lane.md)
```

Inlining the lane-spawn / sync / failure rollup logic in a command file is a CC-04.5 drift signal.

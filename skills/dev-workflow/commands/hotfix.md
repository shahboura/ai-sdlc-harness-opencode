# Hotfix / Rollback Re-Entry

> Authoritative references: [timestamp](../context/timestamp.md), [phase-re-entry](../context/phase-re-entry.md), [workflow-paths](../context/workflow-paths.md), [tracker-transition-rules](../../../agents/shared/tracker-transition-rules.md)

<!-- Created by: dev-workflow-plan.md [M-19] [IMPL-19-01, IMPL-19-03b]
     Reason: NEW cross-cutting re-entry per RAG-26 — surfaces a regression-fix path for already-archived stories.
     Two modes: `un-archive` (clone-not-rename) and `linked-fresh` (bidirectional linkage).
     CC conventions applied: CC-05.1, CC-05.5 (inter-gate-shaped re-entry), CC-07.3, CC-04.3, CC-05.7. -->

**Phase**: Cross-cutting re-entry — touches P3, P5, P5.5, P6, P7, P8.
**Actor**: Orchestrator + human (mode selection); subsequent phase agents (developer / tester / reviewer) per their phase contracts.

## Trigger

`/dev-workflow hotfix <work-item-id> [--mode un-archive|linked-fresh]` typed by the human after a regression is detected post-merge.

## Preconditions

- The target work item has been merged AND P8 reconciliation completed (`tracker.archived.md` exists at `ai/<YYYY-MM-DD>-<work-item-id>/`).
- For `un-archive` mode: the parent's `Workflow completed <ts>` is within the CC-09 `hotfix_unarchive_window_days` (default 30 days). Beyond 30 days, the default mode flips to `linked-fresh` to avoid dragging stale plan context into a fresh fix.

## Mode selection

| Trigger condition | Default mode | Rationale |
|---|---|---|
| Parent archive age < 30 days AND no other hotfix in flight | `un-archive` | Recent context; plan + tracker + reviewer history are still load-bearing. |
| Parent archive age ≥ 30 days OR parent has any open `Hotfixed-By:` link | `linked-fresh` | Plan + amendments are likely superseded; fresh story with provenance link is the clean path. |

The human can override the default via `--mode`.

## Steps — `un-archive` mode (clone-not-rename invariant)

### S1 — Clone the archived tracker

> Authoritative reference: [tracker-transition-rules](../../../agents/shared/tracker-transition-rules.md) — `Archived → In Progress (Hotfix-clone)` is the only legal transition out of `Archived`; it operates on a **clone**, not the original archive.

```bash
SRC=ai/<YYYY-MM-DD>-<work-item-id>/tracker.archived.md
DST=ai/<YYYY-MM-DD>-<work-item-id>/tracker.md
cp "$SRC" "$DST"   # CLONE — never rename or move
```

The original `tracker.archived.md` remains untouched (the FSM hook rejects any attempt to rename it in-place). The clone carries a new header:

```markdown
Hotfix-Of-Archive: tracker.archived.md
Hotfix-Round: 1
```

### S2 — Append the hotfix tasks section

Append a fresh `## Hotfix (Round N)` section to the cloned tracker with the regression's task rows in `⏳ Pending` state. Increment `N` if prior `## Hotfix` sections exist (a story can be hotfixed multiple times).

### S3 — Re-enter P3 via phase-re-entry

> Authoritative reference: [phase-re-entry](../context/phase-re-entry.md)

The orchestrator routes the hotfix tasks through the normal P3 → P5 → P5.5 → P6 → P7 → P8 sequence. The agents read the cloned tracker as if it were any other in-flight tracker.

### S4 — Post-P8 archive numbering

When the hotfix completes P8 reconciliation, the cloned `tracker.md` is renamed to `tracker.archived.hotfix-N.md` (not `tracker.archived.md` — the original archive is preserved). The directory now contains: `tracker.archived.md` (original), `tracker.archived.hotfix-1.md` (post-hotfix), etc.

## Steps — `linked-fresh` mode (bidirectional linkage)

### S1 — Spawn a new workflow directory

```
ai/<YYYY-MM-DD>-<work-item-id-of-hotfix-story>/
```

The hotfix story is a new work item provided by the human (or via a parallel `/dev-workflow requirements` step). The orchestrator enforces the directory uniqueness rule per CC-05.7.2.

### S2 — Inherit parent's plan + amendments

Copy `plan.md` and any amendments from the parent's archived workflow dir into the new dir. Treat the parent's plan as the baseline; the planner amends only the hotfix-specific delta.

### S3 — Write bidirectional linkage headers

Child's `tracker.md`:
```markdown
Hotfix-Of: <parent-work-item-id>
```

Parent's `tracker.archived.md` (append-in-place; the FSM hook permits this single field append for linkage):
```markdown
Hotfixed-By: <child-work-item-id-1>, <child-work-item-id-2>, ...
```

Commit the parent's modified archive with subject `#<parent-id>: link hotfix #<child-id>`.

### S4 — Proceed as a normal workflow

The hotfix story now flows through P1 (skipping requirements ingestion since the regression is the trigger context) → P2 (plan amendment only) → P3..P8 as standard.

## Outputs

| Artifact | Path | Mode |
|---|---|---|
| Cloned tracker | `ai/<parent-dir>/tracker.md` (with `Hotfix-Of-Archive:` header) | un-archive |
| Post-hotfix archive | `ai/<parent-dir>/tracker.archived.hotfix-N.md` | un-archive (after P8) |
| New workflow dir | `ai/<date>-<child-id>/` | linked-fresh |
| Bidirectional linkage | parent `Hotfixed-By:` + child `Hotfix-Of:` headers | linked-fresh |
| Metrics row | `ai/_metrics-log.csv` `round = hotfix-N` | both modes (per M-17 IMPL-19-04 schema bump to 1.2.0) |

## Exit Criteria

1. Cloned (un-archive) or linked-fresh tracker exists at the canonical path.
2. Bidirectional linkage headers present (linked-fresh) or `Hotfix-Of-Archive:` header present (un-archive).
3. Tracker FSM transition `Archived → In Progress (Hotfix-clone)` was permitted by the hook (operates on the clone — the archive itself stays `Archived`).
4. The hotfix tasks complete through P8 reconciliation per normal workflow rules.

## Failure Modes

| Failure | Detection | Response |
|---|---|---|
| Parent archive missing | S1 path resolution | Exit 2 with `parent archive not found: <path>`. |
| FSM rejection of archive rename | hook on Edit/Write to `tracker.archived.md` | Hook surfaces `Archived → * forbidden — clone, do not rename` (this is the clone-not-rename invariant). |
| Parent already has open hotfix in flight | S0 mode-selection scan | Surface to human; the default mode flips to `linked-fresh` if the open hotfix is also `un-archive` (concurrent un-archives are not permitted on the same parent). |
| Bidirectional linkage commit fails on parent's archive | S3 commit step | Surface `.error.md`; the child workflow proceeds, but the parent's reverse link is missing — operator to reconcile later. |

## CC Conventions Applied

- CC-05.1 — Phase contract (Trigger / Preconditions / Steps / Outputs / Exit Criteria / Failure Modes).
- CC-05.4 — Phase boundary enforced by FSM transition + archive rename forbidden.
- CC-05.5 — Inter-gate semantics: enters P3, returns through the same gate sequence as the original workflow.
- CC-05.7 — Per-workflow canonical paths preserved + the new `tracker.archived.hotfix-N.md` suffix.
- CC-04.3 — Citations to phase-re-entry, timestamp, workflow-paths, tracker-transition-rules.
- CC-09 — `hotfix_unarchive_window_days` (default 30) drives mode selection.

## Next Phase

P3 (re-entry on un-archive) or P1/P2 (linked-fresh). Subsequent flow is identical to the normal workflow; the hotfix-specific bookkeeping ends at S3 (un-archive) / S3 (linked-fresh).

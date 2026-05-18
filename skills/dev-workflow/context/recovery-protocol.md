# Recovery Protocol

> Owner: R (Workflow State Recovery)
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-08] [IMPL-08-02]
     Reason: Document the R-phase recovery contract — marker file schema, step ordering, the
     four required fields, and where rotation happens.
     CC conventions applied: CC-04.2, CC-04.4 (owner = R), CC-05.1. -->

## Purpose

Single source for the **R-phase recovery contract** — how the orchestrator persists, reads, and resumes from the `.claude/context/.recovery-state.md` marker file. Per CC-05.4 the marker is the **phase-boundary artifact** for R: its presence (plus current freshness) is what tells the orchestrator a resumable in-progress workflow exists.

## Marker file path

```
<workspace-root>/.claude/context/.recovery-state.md
```

Leading dot — the marker is workspace-local state, never committed (covered by the existing `.gitignore` for `.claude/context/`). One marker per workspace; if two workflows are interleaved on the same workspace (forbidden per CC-05.7.2), the marker reflects the most-recent rotation only.

## Schema

The marker is a markdown document with **four required `Field: Value` lines** (any line not in this set is ignored on read). The fields appear in this canonical order; reader is tolerant to ordering but the writer produces this layout.

| Field | Format | Set by |
|---|---|---|
| `Last completed phase:` | `P0` / `P1` / `P2` / `P2.5` / `P3` / `P4` / `P5` / `P5.5` / `P6` / `P7` / `P8` / `P9` / `IG` / `gate-prompt:<gate-id>` | Orchestrator rotation point (a) `stamp_phase_exit` or (c) `stamp_gate_prompt`. |
| `In-flight tasks:` | `T<n>, T<m>, …` or `none` | Orchestrator rotation point (b) `stamp_tracker_state` — rolls up rows whose `Status` cell contains `🔧 In Progress`. |
| `Dirty worktrees:` | `<path>, <path>, …` or `none` | R Step 3 (`scan worktrees`) — populated on resume; empty on rotation. |
| `Timestamp:` | `YYYY-MM-DD HH:MM UTC` (per [timestamp](timestamp.md)) | Every rotation. |

Example:

```markdown
# Recovery State

Last completed phase: P3
In-flight tasks: T1, T3
Dirty worktrees: web-app-t1-a7c4e102
Timestamp: 2026-05-17 14:30 UTC
```

## Rotation points

The orchestrator rotates the marker at **three** points during normal workflow execution — independent of crash detection:

| Rotation | Trigger | Helper |
|---|---|---|
| (a) | After every successful phase exit (the orchestrator stamps a phase metric in the tracker) | `_recovery_state_writer.stamp_phase_exit(ws, phase_id)` |
| (b) | On every tracker transition (Status column change) | `_recovery_state_writer.stamp_tracker_state(ws, tracker_path)` |
| (c) | At every gate prompt — so R resumes *to* the gate, not before it | `_recovery_state_writer.stamp_gate_prompt(ws, gate_id)` |

> Authoritative reference: [`scripts/_recovery_state_writer.py`](../../../scripts/_recovery_state_writer.py) — composes and writes the marker. Internally uses `_atomic_rename.atomic_write` for crash-safe rotation per CC-03.3 isolation.

## R Step ordering (resume sequence)

When the orchestrator enters the R phase (via `/dev-workflow resume [<id>]` OR via the `stop-failure-recovery.sh` hook routing on `UserPromptSubmit`):

1. **Detect entry mode** — was R triggered by an explicit `/dev-workflow resume` (human-initiated) or by the `.stop-failure` marker (crash-initiated)? Branch on the answer for the next step's verbosity.
2. **Read the marker** at `.claude/context/.recovery-state.md` via `_recovery_state_writer.read_recovery_state`. If absent → emit `Recovery bootstrap-missing <ts>` to the tracker and route to P0 if `.claude/context/state.md` is also absent.
3. **Scan worktrees** — for every repo in `repos-paths.md`, list `git worktree list`, classify each as `preserve` (matches an in-flight task) / `remove` (matches a `Done` task) / `dirty` (uncommitted changes — never auto-remove). Populate `Dirty worktrees:` in the marker.
4. **Present resume summary** — render a per-line summary of:
   - Last completed phase (from marker)
   - In-flight tasks (from marker; cross-referenced with the tracker's `Status` column)
   - Dirty worktrees (with file counts)
   - The single-line `resume_label()` for fast triage
   - Suggested resume target (the phase / gate to re-enter)

5. **Wait for human direction** — emit the resume summary verbatim; do NOT auto-resume to the suggested target. The human picks the resume target via plain text or `/dev-workflow <phase> <id>`.

6. **On resume confirmation**, write `Recovery started <ts>` to the tracker (per `agents/shared/tracker-field-schema.md`) and hand off to the chosen phase command.

> The resume sequence is **read-only** until Step 6 — R does not mutate tracker state on its own. The `.stop-failure` marker (separate from `.recovery-state.md`) is deleted by `stop-failure-recovery.sh` as a one-shot per CC-03.3 isolation.

## Failure modes

| Failure | Detection | Response |
|---|---|---|
| Marker absent | R Step 2 read returns None | Emit `Recovery bootstrap-missing <ts>` to tracker; route to P0 if `state.md` is also absent; otherwise present a "no recovery state — fresh start?" prompt. |
| Marker malformed (missing one of 4 required fields) | `read_recovery_state` returns None for fields-incomplete files | Treat as absent; surface the malformed file path to the human for inspection. |
| Tracker not found at the per-workflow dir referenced by `state.md` `Workflow active` | R Step 3 lookup | Emit `Recovery bootstrap-missing <ts>`; route to P0. |
| Dirty worktree(s) present | R Step 3 `git status --porcelain` non-empty | Populate `Dirty worktrees:` in marker; surface paths verbatim; never auto-clean. |

## Consumers

| Consumer | Use |
|---|---|
| `commands/resume.md` | R Step 4 reader — calls `read_recovery_state` and `resume_label` |
| `workflow-status` skill | Renders the stale-recovery query — reads the marker's `Timestamp:` and `In-flight tasks:` to flag workflows that have been mid-flight for > `gate_stall_threshold_hours` |
| `stop-failure-recovery.sh` | Triggers R routing only — never writes the marker |
| Orchestrator phase-exit / tracker-transition / gate-prompt sites | Rotation points (a) / (b) / (c) above via `_recovery_state_writer` |

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [recovery-protocol](../context/recovery-protocol.md)
```

Inlining the marker schema or rotation rules in a consumer is a CC-04.5 drift signal.

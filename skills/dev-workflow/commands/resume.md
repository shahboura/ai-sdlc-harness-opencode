# R: Workflow State Recovery

> Authoritative references: [recovery-protocol](../context/recovery-protocol.md), [timestamp](../context/timestamp.md), [worktree-lifecycle](../context/worktree-lifecycle.md), [agent-response](../context/agent-response.md)

<!-- Created by: dev-workflow-plan.md [M-08] [IMPL-08-01]
     Reason: NEW phase per GAP-14 — formalises the workflow-state-recovery contract.
     R is a recovery phase entered via human command OR via the stop-failure-recovery hook.
     CC conventions applied: CC-05.1, CC-07.1, CC-04.3, CC-05.4. -->

**Phase**: R (Recovery — between any active phase and the appropriate re-entry point)
**Actor**: Orchestrator only (no agents spawned during R)

## Trigger

Either:

1. **Human-initiated**: `/dev-workflow resume [<work-item-id>]` typed by the user. When `<work-item-id>` is omitted, the orchestrator infers from `.claude/context/state.md` `Workflow active:` field.
2. **Crash-initiated**: the `stop-failure-recovery.sh` UserPromptSubmit hook detects `.claude/context/.stop-failure` and routes the orchestrator's next response into the R flow before the user's message is handled. The hook's recovery prompt block already lists the resume sub-steps; this command formalises the same sequence into a routable phase so re-entry from a saved session works identically.

## Preconditions

- `.claude/context/state.md` is present (`Bootstrap completed` line — per M-02 P0 gate). When absent → route to P0 directly with `Recovery bootstrap-missing <ts>` stamped in the tracker if a tracker is reachable.
- One of: `.claude/context/.recovery-state.md` exists with the 4 required fields per [recovery-protocol](../context/recovery-protocol.md), **or** the `Workflow active:` field in `state.md` references a per-workflow directory with a tracker.
- R may be entered from any active phase or from the workflow-not-yet-running state (a fresh resume on an old workspace).

## Steps

### S1 — Detect entry mode

> Authoritative reference: [recovery-protocol](../context/recovery-protocol.md) (R Step ordering)

Determine whether R was entered via:
- **Human command** (`/dev-workflow resume`) — present a verbose summary; the human is mid-investigation.
- **Crash routing** (`.stop-failure` marker was present on UserPromptSubmit) — present a compact summary; the human has just resumed the session and wants to act, not read.

### S2 — Read the marker

Invoke `scripts/_recovery_state_writer.py read_recovery_state(workspace_root)`. When the marker is absent OR malformed:

- If `.claude/context/state.md` is also absent → emit `Recovery bootstrap-missing <ts>` to the tracker (if a tracker exists) and route to P0.
- Otherwise → emit `Recovery state missing <ts>` and present the human with a "no recovery state — start fresh? abort?" prompt. Do not auto-proceed.

When the marker is present, capture the 4 fields (`Last completed phase`, `In-flight tasks`, `Dirty worktrees`, `Timestamp`) for use in subsequent steps.

### S3 — Scan worktrees

> Authoritative reference: [worktree-lifecycle](../context/worktree-lifecycle.md)

For every repo path in `.claude/context/repos-paths.md`:

1. Run `git -C <repo> worktree list --porcelain` and parse the per-worktree branches.
2. For each worktree whose branch matches `worktree/<story-id>-t<n>-<uid8>`, classify it against the tracker's task table:
   - Task is in `🔧 In Progress` or `🔄 In Review` → **preserve** (the resumed session will pick it up).
   - Task is `✅ Done` or no matching row exists → **remove** (stale from a prior session).
   - Two or more worktrees match the same in-progress task → **preserve the most recent** (use `git -C <wt> log -1 --format=%ct HEAD`; fall back to directory mtime); classify the rest as **remove — duplicate worktree for task T<n>**.
3. Run `git -C <wt> status --porcelain` on every preserve / remove candidate. Any non-empty output → reclassify as **dirty**; never auto-remove a dirty worktree.

Update the marker via `stamp_tracker_state` so `Dirty worktrees:` reflects the current scan.

### S4 — Present resume summary

Render to the human:

```markdown
## Recovery Summary

Resume target: <suggested phase / gate>
Last completed phase: <marker.Last completed phase>
In-flight tasks: <marker.In-flight tasks>
Dirty worktrees: <marker.Dirty worktrees>
Marker timestamp: <marker.Timestamp>
Marker age: <Δ since timestamp>

resume_label: <_recovery_state_writer.resume_label(workspace_root)>

Worktree reconciliation:
| Path | Branch | Task | Classification |
|---|---|---|---|
| ... | ... | T<n> | preserve | remove | dirty |

Decisions required:
1. Confirm resume target (or pick a different phase).
2. Approve / defer the dirty-worktree handling (the orchestrator never auto-cleans).
```

Per CC-05.4 phase-boundary rule, this step is **read-only** — R does not mutate tracker state. The human picks the resume target in a follow-up message.

### S5 — Wait for human direction

R holds here until the human responds with one of:

- A plain confirmation (`yes` / `proceed` / `resume`) → route to the suggested target phase.
- An explicit phase (`develop` / `test` / `create-pr` / etc.) → route to the chosen phase.
- An abort (`abort` / `/dev-workflow abort`) → set `Story-State: Aborted` (per `tracker-transition-rules.md`), stamp `Workflow aborted <ts> — <cause>` in the tracker, and exit. *(The `/dev-workflow abort` command is itself a future M-08 micro-feature; until it exists, the orchestrator interprets `abort` plain-text the same way.)*

### S6 — On resume confirmation

1. Stamp `Recovery started <ts>` in the tracker's Metrics block using the canonical UTC timestamp (see [timestamp](../context/timestamp.md)).
2. Rotate the marker via `stamp_phase_exit(workspace_root, 'R')` so the next failure can recover from the resume point itself.
3. Hand off to the chosen phase command. The phase enters its normal Pre-Flight; the orchestrator's view is that the workflow simply resumed at that phase boundary.

## Outputs

| Artifact | Path | Format |
|---|---|---|
| Resume summary | Inline (presented to human) | Markdown block per S4 |
| Tracker metric | Tracker `## Metrics` block | `Recovery started <ts>` |
| Marker rotation | `.claude/context/.recovery-state.md` | Updated `Last completed phase: R` + `Timestamp:` |

## Exit Criteria

1. Marker read and resume summary surfaced to human (S2 + S4 complete).
2. Human-confirmed resume target OR abort decision.
3. On resume: `Recovery started <ts>` written to tracker; orchestrator routed to the chosen phase command. On abort: `Workflow aborted <ts>` written; tracker `Story-State: Aborted`.

## Failure Modes

| Failure | Detection | Response |
|---|---|---|
| Marker absent + `state.md` absent | S2 returns None + S1 check | Route to P0 with `Recovery bootstrap-missing <ts>`. |
| Marker malformed | `read_recovery_state` returns None for fields-incomplete file | Surface the malformed path; do not auto-replace. |
| Tracker missing for the active workflow | S3 cannot find the tracker referenced by `state.md` `Workflow active:` | Emit `Recovery bootstrap-missing <ts>` to a fresh tracker location; route to P0 fallback. |
| Dirty worktree(s) present | S3 reclassification | Surface paths verbatim; require human acknowledgement before any cleanup. |
| Human direction times out | S5 — no response within `gate_stall_threshold_hours` (CC-09 default 24h) | Surface a stale-resume reminder via `workflow-status`; R remains in S5 until the human responds. |

## CC Conventions Applied

- CC-05.1 — Phase contract (Trigger / Preconditions / Steps / Outputs / Exit Criteria / Failure Modes — all declared above).
- CC-05.4 — Phase boundary: the marker file is the structural artifact; R is read-only until S6.
- CC-05.3 — Explicit phase exit signal (`Recovery started <ts>` metric stamp).
- CC-04.3 — All shared snippets cited via `> Authoritative reference: ...`.
- CC-07.1 — Phase-spec required headers (canonical-spec header + Phase / Actor / Trigger / Preconditions / Steps / Outputs / Exit Criteria / Failure Modes).

## Next Phase

Determined by S5 human direction. Typical routes:
- `develop` → resume P3 mid-task.
- `test` → resume P5 hardening.
- `create-pr` → resume P6 PR creation.
- `review-response` → resume P7.
- `abort` → terminal `Aborted` state; no next phase.

When the resume target is itself blocked (e.g. provider unreachable), the target phase emits `Outcome: BLOCKED`, which routes back into R for a fresh resume attempt.

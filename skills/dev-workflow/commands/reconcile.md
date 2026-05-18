# Phase 8: Post-Merge Reconciliation

> Authoritative references: [provider-resolver](../context/provider-resolver.md), [summary-render](../context/summary-render.md), [timestamp](../context/timestamp.md), [worktree-lifecycle](../context/worktree-lifecycle.md)

> Naming-config (M-15 IMPL-15-04): the archive-rename step writes `tracker.archived.md` (canonical M-14 path) and the optional terminal-stamp commit subject is read from `.claude/context/naming-config.md` `commit_format:` per CC-01.8 — never hardcoded. The `_validate_commit_msg.py` hook validates any commit subject this command emits against the configured template.

<!-- Created by: dev-workflow-plan.md [M-07] [IMPL-07-01..06]
     Reason: NEW phase per GAP-13 — post-merge reconciliation closes the workflow loop by
     transitioning the work item to its terminal state, archiving the tracker, and cleaning up
     stale worktrees. Follows the CC-05.1 phase-spec template.
     CC conventions applied: CC-05.1, CC-04.3, CC-07.3, CC-01.5, CC-01.6, CC-03.3, CC-08.1. -->

**Phase**: 8
**Actor**: Orchestrator (no agents spawned in P8 unless the provider lacks `work_item.transition`)

## Trigger

`/dev-workflow reconcile <work-item-id>` invoked by the human after PR merge is detected (or after `/dev-workflow review-response` completes its post-merge stamp). The orchestrator may also auto-route to this phase when a PR-merge webhook / detection mechanism is present.

## Preconditions

- The story's PR has been merged into the target branch (detected via the git provider's `pr.merge_status` capability per [provider-resolver](../context/provider-resolver.md)).
- The story's tracker is in `Story-State: Done` (Phase 7 closed cleanly OR Phase 6 closed without amendments and no Phase 7 was needed).
- The configured providers declare the required capabilities (`pr.merge_status` for detection; `work_item.transition` ideally — graceful degradation per Failure Modes below).
- `.claude/context/state.md` shows `Bootstrap completed`.

## Steps

### S1 — Verify merge

> Authoritative reference: [provider-resolver](../context/provider-resolver.md)

Resolve the git provider adapter and call its `pr.merge_status` primitive for the story's PR. If the PR is open or closed-without-merge, **exit 2** with `Reason: PR <id> not merged — refuse to reconcile`.

Record `Merge detected <ts>` to the tracker's Metrics block using the canonical UTC timestamp (see [timestamp](../context/timestamp.md)).

### S2 — Transition the work item

Resolve the work-item provider adapter; check if it declares `work_item.transition` with status `✅` in its `## Capabilities` table.

- **Capability present**: call the adapter's `work_item.transition` primitive with the configured terminal state (`Closed` / `Done` / `Resolved` — adapter-specific, declared in the provider config). Wait for success acknowledgement before proceeding to S3.
- **Capability absent or `❌`**: emit a human-facing prompt:
  > `❌ Provider <name> does not support work_item.transition. Transition <story-id> to its terminal state manually, then re-run /dev-workflow reconcile <id> --skip-transition.`
  Exit with code 2 per CC-01.5 precondition semantics — the human transitions the item and re-runs.
- **Capability emulated (🟡)**: invoke the emulated path documented in the adapter and proceed; surface to the human that the transition was emulated.

### S3 — Render per-repo summary

> Authoritative reference: [summary-render](../context/summary-render.md)

Render the multi-repo summary block (one row per repo touched by this story) and append it to the tracker. The summary is the audit footprint of what was reconciled — branch names, final commit hashes, coverage percentages.

### S4 — Archive the tracker

Rename the tracker in place (per CC-05.7 post-M-14 layout):

```
ai/<YYYY-MM-DD>-<work-item-id>/tracker.md  →  ai/<YYYY-MM-DD>-<work-item-id>/tracker.archived.md
```

Use the atomic rename primitive (`scripts/_atomic_rename.py atomic_rename`) introduced in M-08 IMPL-08-07 — never plain `mv`, which is not crash-safe across filesystems.

Within the archived tracker, set every task row's `Status` from `✅ Done` to `📦 Archived` (FSM allows this transition per M-07 IMPL-07-04). Also set the story-level `Story-State:` field to `Archived`.

Record `Workflow completed <ts>` to the tracker's Metrics block BEFORE the rename — the metric must land in the file before it changes name (the rename does not affect the metric's content, only its location).

### S5 — Sweep worktrees

> Authoritative reference: [worktree-lifecycle](../context/worktree-lifecycle.md)

For every worktree on disk under `<repo>/../worktrees/` whose name starts with `<repo>-t<n>-<uid8>` for the reconciled story:

1. Check `git -C <worktree-path> status --porcelain` — if dirty (uncommitted changes), **do not delete**; surface the worktree path verbatim to the human and continue. Per CC-01.5 NO_OP semantics, a partial sweep is not a failure.
2. If clean, run `git -C <repo-path> worktree remove --force <worktree-path>` and delete the corresponding worktree branch (`git -C <repo-path> branch -D worktree/<story-id>-t<n>-<uid8>`).
3. Record per-worktree disposition (`removed` / `dirty — skipped`) in the final summary.

### S6 — T3 Metrics Collection

Per the P9 metrics-collector contract (`skills/metrics-collector/SKILL.md`),
P8 triggers the terminal metrics aggregation at **T3** with `--round final`
after the tracker rename (S4) has produced `tracker.archived.md`. This is
the last row appended to `ai/_metrics-log.csv` for this work-item — it
captures the complete cycle from `Plan approved` through `Workflow
completed`.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/metrics_collector.py" \
    "ai/<YYYY-MM-DD>-<work-item-id>" \
    --round final
```

The aggregator discovers `tracker.archived.md` ahead of `tracker.md` and
reads from it, so the `--round final` row reflects the archived state.
Exit semantics: `0` success, `1` validation failure with `.error.md`
sibling, `2` precondition unmet. On non-zero, surface `.error.md` to the
human but do not block reconcile completion — the PR is merged and the
work item is closed; the metrics row is a non-blocking observation.

## Outputs

| Artifact | Path | Format |
|---|---|---|
| Archived tracker | `ai/<YYYY-MM-DD>-<work-item-id>/tracker.archived.md` | Markdown (renamed from `tracker.md`); story-state `Archived`; all rows `📦 Archived`; `Workflow completed <ts>` present |
| Reconciliation summary | Inline in the archived tracker (S3 output) | Per-repo summary block per `summary-render.md` |
| Metric stamps | Tracker Metrics block | `Merge detected <ts>`, `Workflow completed <ts>` |

## Exit Criteria

1. PR confirmed merged (S1).
2. Work item transitioned to terminal state (S2) — OR human acknowledged the transition manually when the provider lacks the capability.
3. Tracker renamed to `tracker.archived.md` (S4) with all rows in `📦 Archived` and `Story-State: Archived`.
4. Worktree sweep completed (S5) — clean worktrees removed; dirty worktrees surfaced verbatim.
5. `Workflow completed <ts>` and `Merge detected <ts>` metric stamps present in the archived tracker.

## Failure Modes

| Failure | Detection | Response |
|---|---|---|
| PR not merged | S1 git-provider check returns merge_status ≠ merged | Exit 2; `Reason: PR not merged`. Re-run when merge lands. |
| `work_item.transition` capability absent | S2 capability check fails | Exit 2 with human-fallback prompt (per CC-01.5); re-run with `--skip-transition` after manual transition. |
| Atomic rename failure | S4 `os.rename` raises | Exit 2 with stderr `tracker rename failed: <cause>`; tracker remains as `tracker.md` for safe retry. |
| Dirty worktree(s) found in sweep | S5 `git status --porcelain` non-empty | NO_OP for that worktree (do not delete); other worktrees still swept; surface the dirty paths to the human in the final summary. |
| Provider RTE during transition | S2 adapter call throws | BLOCKED; surface adapter error verbatim; re-run after the provider issue is resolved. |

## CC Conventions Applied

- CC-05.1 — Phase contract (Trigger / Preconditions / Steps / Outputs / Exit Criteria / Failure Modes — all declared above).
- CC-05.3 — Explicit phase exit signal (`Workflow completed <ts>` metric stamp).
- CC-05.4 — Phase boundary (the tracker rename is the structural marker; the orchestrator refuses to re-enter a phase against an archived tracker).
- CC-05.7 — Canonical per-workflow paths (post-M-14 layout: `tracker.archived.md` in-place rename).
- CC-04.3 — All shared snippets cited via `> Authoritative reference: ...`.
- CC-01.5 — Exit codes (0 success, 2 precondition unmet) + NO_OP semantics for partial worktree sweep.
- CC-01.6 — Recognised as a router-routable command (see SKILL.md router update IMPL-07-02).
- CC-03.3 — The transition guard hook isolation is preserved (it permits but does not initiate the `Done → Archived` transition).
- CC-08.1 — DRY: no inline reproduction of provider-resolver / summary-render / timestamp / worktree-lifecycle prose.

## Next Phase

Workflow Complete. The orchestrator emits the workflow-complete summary to the human and unsets `Workflow active` in `.claude/context/state.md`.

If a regression appears post-merge, route through `/dev-workflow hotfix <id>` (M-19) — operates on a clone, the archived tracker is preserved.

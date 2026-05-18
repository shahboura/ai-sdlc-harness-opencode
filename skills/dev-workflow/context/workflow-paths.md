# Per-Workflow Artifact Path Layout

> Owner: M-14 (path migration milestone — introduces the layout for the first time)
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-14] [IMPL-14-03]
     Reason: Canonical declaration of the per-workflow path layout per CC-05.7. Replaces the
     legacy split-directory layout (ai/plans/ + ai/tasks/). Owner per CC-08.5 is M-14, not M-01,
     because this is the first time the layout is asserted.
     CC conventions applied: CC-04.2, CC-04.4, CC-04.6, CC-05.7, CC-05.7.1, CC-05.7.2. -->

## Purpose

Single source for the **canonical per-workflow artifact layout** under `ai/`. Per CC-05.7 every phase produces canonical artifacts at predictable per-workflow paths under one directory; this file declares the directory shape, the per-artifact filenames, and the `-<n>` / `-<repo>` suffix rules.

## Canonical layout

```
ai/<YYYY-MM-DD>-<work-item-id>/
    plan.md                                     # P2  — plan-generator output
    tracker.md                                  # P2  — plan-generator output; archived to tracker.archived.md by P8
    test-outline.md                             # P2  — plan-generator output (Red-test outlines)
    contracts.md                                # P2  — plan-generator output (multi-repo only; absent on single-repo stories)
    coverage-report-<repo>.md                   # P5  — per-repo coverage report (fan-out lane)
    pre-pr-report.md                            # P6  — reviewer pre-PR holistic report (single, multi-repo)
    pr-comment-analysis-report-<n>.md           # P7  — per-cycle review-comment analysis (monotonically increasing n)
    static-security-report-<repo>.md            # P5.5 — per-repo SAST scan output (fan-out lane)
    metrics-report.md                           # P9  — metrics-collector aggregate
    requirements-summary.md                     # P1  — story-intake's canonical requirements summary (CC-05.7)
    .last-requirements.md                       # P1  — R recovery marker for partial P1 runs

ai/_metrics-log.csv                              # Workspace-level (cross-story); leading underscore distinguishes
ai/.snapshots/                                   # Workspace-level (handle-request plan-amendment snapshots)
```

## Naming rules

- **`<YYYY-MM-DD>`** — the date the workflow started (P1 entry).
- **`<work-item-id>`** — the provider-native ID after `safe_id()` normalisation. Per CC-05.7.1 the segment must match `[A-Za-z0-9._-]+`.
  > Authoritative reference: [safe-id](../../providers/shared/safe-id.md)
- **`<repo>`** — repo slug post-`safe_id()`. One coverage / security report per repo when the phase fans out.
- **`-<n>`** — monotonically increasing 1-based integer for multi-round artifacts (P7 comment analysis fires once per review cycle).

## Suffix rules

| Suffix | Meaning | Phases |
|---|---|---|
| `-<repo>` | Per-repo fan-out artifact | P5 (`coverage-report`), P5.5 (`static-security-report`) |
| `-<n>` | Per-round artifact (monotonically increasing) | P7 (`pr-comment-analysis-report`) |
| `.archived.md` | In-place rename of `tracker.md` after P8 reconciliation | P8 |
| `.aborted.md` | In-place rename of `tracker.md` after R abort | R |

## Legacy paths (deprecated; do not write)

The legacy layout split per-story files across two directories:

```
ai/plans/<work-item-id>.md          # legacy plan
ai/tasks/<work-item-id>.md          # legacy tracker
```

**Both paths are deprecated**. Read-side compatibility is preserved during the migration window:
- Hooks that match tracker paths (`_tracker_transition_guard.py`, `_tracker_metrics_guard.py`, `_tracker_update_reminder.py`, `_tester_activation_guard.py`) accept BOTH `ai/tasks/...` AND `ai/<date>-<id>/tracker*.md` patterns.
- The migration script `scripts/migrate-ai-layout.sh` (IMPL-14-04) is the one-time tool that moves in-flight stories from the legacy layout into the new directory shape.
- Convention-Check `CC05-artifact-path-layout.convention-check.test.sh` (M-13) ensures no NEW consumer writes to legacy paths.

## Single-developer-per-story collision detection (CC-05.7.2 — RAG-29)

> Authoritative reference: cc-conventions.md → CC-05.7.2 + CC-05.7.2.1 (non-interactive mode).

P1 entry MUST glob `ai/*-<work-item-id>/` (any date prefix) before spawning the planner. On hit, the orchestrator presents a 2-choice prompt:

1. **Takeover** — reuse the existing tracker; the planner's status block reports `Tracker source: existing`. No overwrite.
2. **Abort** — rename `tracker.md → tracker.aborted.md` (atomic per `_atomic_rename.atomic_rename`); stamp `Recovery abandoned <ts>` on the renamed file; exit cleanly.

Non-interactive mode (CI / `--non-interactive` / non-TTY stdin) per CC-05.7.2.1: the orchestrator refuses to proceed and exits with `[CC-05.7.2] workflow-dir collision detected at <path>; no human decision available — refuse to proceed.` Silent overwrite is forbidden.

## Consumers

| Phase | Site | Path used |
|---|---|---|
| P1 | `commands/requirements.md` + `story-intake` | `requirements-summary.md`, `.last-requirements.md` |
| P2 | `commands/plan.md` + `plan-generator` | `plan.md`, `tracker.md`, `test-outline.md`, `contracts.md` (multi-repo only) |
| P5 | `commands/test.md` | `coverage-report-<repo>.md` |
| P5.5 | `commands/security-review.md` | `static-security-report-<repo>.md` |
| P6 | `commands/create-pr.md` | `pre-pr-report.md` |
| P7 | `commands/review-response.md` | `pr-comment-analysis-report-<n>.md` |
| P8 | `commands/reconcile.md` | `tracker.archived.md` (in-place rename) |
| P9 | `commands/metrics.md` | `metrics-report.md` |
| R | `commands/resume.md` | `tracker.aborted.md` (in-place rename on abort) |
| Hooks | `_tracker_*.py` | Read-side compatibility for legacy + new |

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [workflow-paths](../context/workflow-paths.md)
```

Inlining the path shape in a consumer is a CC-04.5 drift signal.

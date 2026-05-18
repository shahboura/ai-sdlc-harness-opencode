# Summary Render

> Owner: cross-cutting
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-05]
     Reason: Foundational shared snippet — extracts the per-repo summary block format duplicated at 4 sites.
     CC conventions applied: CC-04.2, CC-04.4 -->

## Purpose

Single source for the per-repo summary block format used at every fan-out aggregation point: P4 approval, P6 PR creation, P7 review response, and IG request handling. Per CC-05.6, every parallel-lane phase must aggregate lane outputs into one structured block before the gate.

## Per-repo summary block format

```markdown
### Repo: <repo-name>

**Branch**: <branch-name>
**Tasks completed**: <n> / <total>
**Tests Green**: <n> / <total>
**Coverage (new/modified)**: <pct>%
**Build**: <PASS | FAIL | NOT_RUN>
**Outstanding**: <one-line summary or "none">
```

## Multi-repo aggregation block

When > 1 repo is touched, the summary is wrapped in an aggregation header:

```markdown
## Multi-Repo Summary
**Repos touched**: <n>
**Cross-repo contract**: <PASS | FAIL | N/A>
**Aggregated coverage**: <pct>%

<per-repo block 1>
<per-repo block 2>
...
```

## Field semantics

| Field | Type | Source | Notes |
|---|---|---|---|
| `Repo` | string | `provider-config.md` | Repo slug after `safe_id()` normalisation. |
| `Branch` | string | `naming-config.md` template | Rendered from `${branch_default}` template per CC-01.8. |
| `Tasks completed` | `n / total` | `tracker.md` | Counts tasks in `Done` state. |
| `Tests Green` | `n / total` | `tracker.md` per task | Aggregates the `T-TEST: <state>` rows. |
| `Coverage` | percent | tester output | Per CC-09 the gate is >= 90% unless overridden. |
| `Build` | enum | last build log | `NOT_RUN` is valid only if the build was intentionally skipped (e.g. docs-only PR). |
| `Outstanding` | string | reviewer / IG | Free-text — one line. Multi-line outstanding lists must be linked, not inlined. |

## Consumers

| Phase | Site |
|---|---|
| P4 | `commands/approve-impl.md` Step 4 (pre-gate summary to human) |
| P6 | `commands/create-pr.md` Step 3 (pre-PR report shown to human at GATE #3) + Step 7 (pr-creator invocation; the same summary is used to assemble the PR description body) |
| P7 | `commands/review-response.md` Step 7 (re-routing summary) |
| IG | `commands/handle-request.md` Step 6 (ad-hoc completion summary) |

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [summary-render](../context/summary-render.md)
```

Inlining the per-repo block format in a command file is a CC-04.5 drift signal.

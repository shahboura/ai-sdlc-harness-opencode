# Timestamp Helper

> Owner: cross-cutting
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-01]
     Reason: Foundational shared snippet — extracts the canonical UTC timestamp invocation duplicated at >=13 sites.
     CC conventions applied: CC-04.2, CC-04.4, CC-04.6, CC-08.5 -->

## Purpose

Canonical source for the UTC timestamp string used in every workflow metric stamp (`Plan approved <ts>`, `Task Started <ts>`, `Gate prompted <ts>`, etc.). Every workflow metric must be emitted with the exact same shape so downstream metrics-collectors can parse them deterministically.

## Canonical invocation

```bash
date -u +"%Y-%m-%d %H:%M UTC"
```

Output shape: `2026-05-17 13:24 UTC`. Minute-precision only — the workflow never claims second-precision because metric stamps are stamped from human-driven commands, not high-frequency events.

## Usage example

```bash
TS=$(date -u +"%Y-%m-%d %H:%M UTC")
echo "Plan approved $TS" >> "$tracker"
```

## Consumers

| Phase | Site | Metric |
|---|---|---|
| P0 | `init-workspace` | `Bootstrap completed <ts>` |
| P2 | `commands/plan.md` Step 6 | `Plan approved <ts>` |
| P3 | `commands/develop.md` Step 4 | `Task Started <ts>` / `Task Completed <ts>` |
| P3 | `commands/develop.md` Step 8 | `Initial development completed <ts>` |
| P4 | `commands/approve-impl.md` Step 5 | `Human approval (impl) <ts>` |
| P5 | `commands/test.md` Step 6 | `Test hardening completed <ts>` |
| P5.5 | `commands/security-review.md` Step 6 | `Security review completed <ts>` (plus `Gate #2.5 <decision> <ts>` when the gate fires) |
| P6 | `commands/create-pr.md` Step 9 | `PR created <ts>` |
| P7 | `commands/review-response.md` Step 9 | `PR review response completed <ts>` |
| P8 | `commands/reconcile.md` | `Merge detected <ts>` |
| P9 | `commands/metrics.md` | `Metrics collected <ts>` |
| IG | `commands/handle-request.md` | `Request handled <ts>` |
| R | `commands/resume.md` | `Recovery started <ts>` |

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [timestamp](../context/timestamp.md)
```

Reproducing the `date -u` invocation inline outside this file is a CC-04.5 drift signal.

# Phase Re-Entry

> Owner: cross-cutting
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-07]
     Reason: Foundational shared snippet — extracts the identical P3 re-entry + P5 re-trigger block from review-response.md Step 8b and handle-request.md Step 7b.
     CC conventions applied: CC-04.2, CC-04.4 -->

## Purpose

Single source for the "re-enter P3 for amendments / ad-hoc tasks; re-trigger P5 on affected repos" sequence. Both P7 (review-response) and IG (handle-request) need to push work back through P3 → P5 when a comment requires source changes; the sequence is identical and was previously duplicated verbatim at the two sites (GAP-07).

## Re-entry sequence

### Step 1 — Decide re-entry scope

For each routed comment / request (per `comment-routing.md`):

1. **Determine the affected repo(s)** from the comment / request file paths.
2. **Determine the affected task(s)** by looking up the file path in the plan's task-to-file map.
3. **Mark the affected tracker rows** with state `In Progress` (CC-04 transition allowed by `tracker-transition-rules.md`).

### Step 2 — Re-enter P3 (per affected task)

Re-enter the P3 development loop scoped to the affected tasks only:

1. Re-use the existing task worktree (per `worktree-lifecycle.md`) — do not create a new one.
2. Spawn the developer agent with the routed comment as context (developer mode is unchanged — the agent is the same single-mode developer agent).
3. Wait for `Outcome: SUCCESS` and a fresh build pass.

### Step 3 — Re-trigger P5 on affected repos

For each repo whose source changed:

1. Check the **T-TEST status** on each affected task:
    - `T-TEST: COVERED` → re-run the test suite only.
    - `T-TEST: PARTIAL` → spawn tester agent in `auto-harden` mode for the affected tasks.
    - `T-TEST: ABSENT` → spawn tester agent in `auto-tdd` mode for the affected tasks.
2. Aggregate per-repo summaries per `summary-render.md`.

### Step 4 — Re-emit affected-tasks metric stamp

```bash
TS=$(date -u +"%Y-%m-%d %H:%M UTC")  # Authoritative reference: timestamp.md
echo "Re-entered P3 for tasks <list> at $TS" >> "$tracker"
```

## T-TEST status check details

The `T-TEST: <state>` field is a tracker-task row column declared in `agents/shared/tracker-field-schema.md`. The three allowed values:

| Value | Meaning |
|---|---|
| `ABSENT` | No test exists for the task's behaviour yet (TDD red-verify will be required per M-20). |
| `PARTIAL` | A test exists but coverage is below the CC-09 threshold for new/modified lines. |
| `COVERED` | A test exists and coverage meets/exceeds the threshold. |

## Consumers

| Phase | Site | Reason for re-entry |
|---|---|---|
| P7 | `commands/review-response.md` Step 8b | Reviewer comment requires source change |
| IG | `commands/handle-request.md` Step 7b | Ad-hoc request requires source change |

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [phase-re-entry](../context/phase-re-entry.md)
```

Inlining the re-entry sequence in a command file is a CC-04.5 drift signal — this is exactly the duplication GAP-07 documented.

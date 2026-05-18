# Phase 4: Human Approval of Implementation

> Authoritative references: [timestamp](../context/timestamp.md), [summary-render](../context/summary-render.md)

<!-- Changed by: dev-workflow-plan.md [M-05] [IMPL-05-01, IMPL-05-04]
     Reason: Add canonical-spec header + citations to summary-render + timestamp per CC-04.3 / CC-07.3 / CC-08.5.
     CC conventions applied: CC-04.3, CC-07.3, CC-08.5. -->

**Phase**: 4
**Actor**: Orchestrator, then Human gate

## Prerequisites

- ALL development tasks are ✅ Done in the tracker.
- Phase 3 complete.
- If in direct phase mode, verify by reading the tracker:
  - All T(n) tasks must have status ✅ Done.
  - `Development started` metric must be set.

## Steps

### Record Metric

Set `Initial development completed` to the canonical UTC timestamp (see [timestamp](../context/timestamp.md)). The metric records the **first** Phase 3 close — Phase 7 amendments and ad-hoc batches that re-enter Phase 3 are tracked by their own `PR review response completed` / `Ad-hoc requests completed` fields and do NOT re-stamp this one.

### Present Summary

Read the task tracker and present a per-repo summary per [summary-render](../context/summary-render.md):
- Story ID and title
- **Per-repo breakdown**:
  - Repo name and branch
  - List of completed tasks with commit hashes
  - Number of files changed (`git -C <repo-path> diff --stat <default-branch>...HEAD`)
- Link to the plan document

**Review round callout** — if any task has `Review Rounds > 0` in Task Metrics, append:

```
### Review Rounds
The following tasks required multiple review rounds during Phase 3.
Full reviewer comments are in the ## Review History section of the tracker.

| Task | Rounds |
|------|--------|
| T<n> | <Review Rounds> |
```

If all tasks were approved on the first pass, omit this section entirely.

### HUMAN GATE #2

Present the summary using this multi-choice prompt:

```
## Phase 4: Implementation Approval

<display per-repo summary>

Options:
  [1] APPROVED — proceed to Phase 5 (test hardening)
  [2] CHANGES — describe rework you want against the existing plan
  [3] REQUEST <description> — submit an ad-hoc request (issue found while testing,
      out-of-scope idea, or change against the approved plan). Every request is
      triaged against the plan and acceptance criteria before any code work begins;
      in-scope items create tasks under a separate `## Ad-hoc Tasks` heading;
      out-of-scope items are surfaced back to you with explicit options.

Type 1, describe changes for option 2, or `REQUEST <text>` for option 3.
```

**On `[1] APPROVED`**: continue to *Record Approval Metric* below.

**On `[2] CHANGES`**: relay the comments per the standard Phase 3 review-comment routing
and loop back to `commands/develop.md` for the affected tasks.

**On `[3] REQUEST <text>`**: invoke `commands/handle-request.md` with `Source: gate-2`,
`Submission phase: 4`, and the verbatim request text. After the request batch is fully
processed (Step 8 of handle-request.md returns to this gate), re-present the per-repo
summary — it now reflects the additional ad-hoc task commits — and re-prompt with the
same multi-choice block.

### Record Approval Metric

On approval, set `Human approval (impl)` to the canonical UTC timestamp (see [timestamp](../context/timestamp.md)).

## Next Phase

Proceed to **Phase 5: Test** — read and execute `commands/test.md`.

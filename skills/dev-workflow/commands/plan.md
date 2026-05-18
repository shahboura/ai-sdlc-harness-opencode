# Phase 2: Planning & Approval

> Authoritative references: [timestamp](../context/timestamp.md), [agent-response](../context/agent-response.md), [provider-resolver](../context/provider-resolver.md)

<!-- Changed by: dev-workflow-plan.md [M-11] [IMPL-11-01]
     Reason: Add canonical-spec header per CC-07.3 — this command is an execution script;
     the phase contract lives in the spec.
     CC conventions applied: CC-07.3. -->

**Phase**: 2
**Actor**: Planner agent, then Human gate

## Prerequisites

- Phase 1 complete — requirements confirmed by the Planner.
- **No feature branch is required.** Branches are created in Pre-flight (after this phase) once the Planner has identified the affected repos. Phase 1 and Phase 2 produce only workspace files at `ai/<YYYY-MM-DD>-<work-item-id>/{plan,tracker,test-outline}.md` (new canonical layout per [workflow-paths](../context/workflow-paths.md)); the workspace's own branch is irrelevant.
- If in direct phase mode, verify requirements were ingested by checking for Planner output
  or by re-running Phase 1 first.

## Steps

### Step 1: Design Approach Selection

Delegate to **@ai-sdlc-planner**:

```
@ai-sdlc-planner Before decomposing User Story $ARGUMENTS into tasks, propose 2-3 architectural
approaches for implementing this story. For each approach, provide:
1. A short name and one-line summary
2. High-level design (which layers, services, and types are involved)
3. Trade-offs (complexity, performance, maintainability, risk)
4. Your recommendation with reasoning

Present the approaches in a structured DESIGN APPROACHES block for the human to choose from.
Do NOT proceed to task decomposition until the human selects an approach.
```

Present the approaches to the human and wait for a selection. The human may pick one,
request a hybrid, or ask for different options.

### Step 2: Task Decomposition

> **Orchestrator rule:** Do NOT include explicit file paths in the prompt to the Planner.
> The plan-generator skill owns the naming convention (date-prefixed). Providing a path
> causes the Planner to use it instead of the skill's convention, losing the date prefix
> and session ID. Let the skill determine the paths.

Once the human selects an approach, continue with **@ai-sdlc-planner**:

```
@ai-sdlc-planner The human selected approach: <SELECTED-APPROACH>.
Decompose User Story $ARGUMENTS into an implementation plan using this approach.
Use the plan-generator skill. Save the plan and task tracker files.
Present the complete plan for human approval.
```

### HUMAN GATE #1

The plan **must** be presented to the human user. Proceed **only** on a reply that matches the canonical approval matcher declared in [`context/orchestrator-rules.md`](../context/orchestrator-rules.md) → *Human Approval Signal — canonical matcher* (case-insensitive `APPROVED`, optional trailing `.`, no embedded qualifications).
If changes are requested, have the Planner revise and re-present.

### Record Metric: Plan Approved

Update the tracker's **Workflow Metrics** table — set `Plan approved` to the current UTC timestamp:
```bash
date -u +"%Y-%m-%d %H:%M UTC"
```

### Plan Commit Deferred to Pre-flight

The plan is **not** committed at this step. In the previous workflow ordering (preflight
before Phase 1), the feature branch was already checked out by the time Phase 2 finished and
the plan commit could land on it directly. In the current ordering (preflight after Phase 2),
the feature branch does not yet exist — committing here would put the plan on the default
branch, which is wrong.

The plan commit moves into `commands/preflight.md` (single-repo workspace-is-git-repo case
only) so it lands on the just-created feature branch. The workspace-not-a-git-repo case is
unchanged: the plan stays at `<WORKSPACE_ROOT>/ai/<YYYY-MM-DD>-<work-item-id>/plan.md` (or legacy `<WORKSPACE_ROOT>/ai/plans/<id>.md`) per orchestrator rule #8 and
travels into each affected repo alongside the tracker in Phase 6 (`commands/create-pr.md`
Step 6).

**The task tracker is NOT committed in this phase or in preflight either.** It remains an
uncommitted working file that the orchestrator updates in-place throughout Phases 3-5. It is
committed once before PR creation in Phase 6.

## Next Phase

Proceed to **Pre-flight** — read and execute `commands/preflight.md`. Preflight reads the
tracker's `## Repo Status` section (populated by the Planner per `plan-generator/SKILL.md`
Step 7) to create feature branches in exactly the repos the plan named, then commits the
plan (single-repo workspace-is-git-repo case only) onto the new feature branch.

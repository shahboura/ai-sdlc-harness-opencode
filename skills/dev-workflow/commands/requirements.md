# Phase 1: Requirements Ingestion

> Authoritative references: [provider-resolver](../context/provider-resolver.md), [timestamp](../context/timestamp.md), [agent-response](../context/agent-response.md)

<!-- Changed by: dev-workflow-plan.md [M-11] [IMPL-11-01]
     Reason: Add canonical-spec header per CC-07.3.
     CC conventions applied: CC-07.3. -->

**Phase**: 1
**Actor**: Planner agent

## Prerequisites

- **Workspace Branch Sync has run.** Per `SKILL.md` → *Workspace Branch Sync*, the orchestrator ensures every repo in `repos-paths.md` is on its default branch with latest pulled before Phase 1 begins. If any repo had uncommitted changes on a non-default branch, the human has already been prompted with the `[a] stash / [b] skip / [c] abort` choice — Phase 1 does not re-prompt.
- **No feature branch is required.** Phase 1 produces no commits — it only fetches the story and surfaces clarifying questions. Pre-flight (which creates the feature branches) now runs after Phase 2, once the Planner has identified the affected repos. See `commands/preflight.md` for the post-B2 ordering rationale.
- If in direct phase mode, no additional verification — this is the entry point.

## Steps

### S0 — Workflow-directory collision detection (CC-05.7.2 — IMPL-14-07)

<!-- Changed by: dev-workflow-plan.md [M-14] [IMPL-14-07]
     Reason: P1 entry must detect a pre-existing workflow directory and prompt the human
     before any planner spawn — silent overwrite is forbidden per CC-05.7.2.
     CC conventions applied: CC-05.7.2, CC-05.4, CC-04.3. -->

> Authoritative reference: [workflow-paths](../context/workflow-paths.md)

Before spawning the planner, run:

```bash
WORK_ITEM_ID=$(safe_id "$ARGUMENTS")  # see skills/providers/shared/safe-id.md
EXISTING=$(ls -d ai/*-${WORK_ITEM_ID}/ 2>/dev/null)
```

On collision (`$EXISTING` non-empty):

1. **Interactive mode** — surface a 2-choice prompt to the human:
   ```
   ⚠ A workflow directory for <work-item-id> already exists at <path>.
       [Takeover]  Use the existing tracker (preserves prior progress).
       [Abort]     Rename tracker.md → tracker.aborted.md and exit.
   ```
   - **Takeover** → reuse the existing tracker; the planner's status block reports `Tracker source: existing` (not `new`).
   - **Abort** → call `scripts/_atomic_rename.py atomic_rename(<existing>/tracker.md, <existing>/tracker.aborted.md)`; stamp `Recovery abandoned <ts>` on the renamed file; exit cleanly with exit code 0.

2. **Non-interactive mode** (CI, `--non-interactive` flag, or non-TTY stdin per CC-05.7.2.1) — refuse to proceed:
   ```
   [CC-05.7.2] workflow-dir collision detected at <path>; no human decision
   available — refuse to proceed. Re-run interactively or pass --takeover /
   --abort explicitly.
   ```
   Exit code 2.

Silent overwrite of an existing workflow directory is **forbidden**. The `safe_id()` normalisation ensures the glob is deterministic — two distinct provider IDs cannot collapse to the same directory.

Delegate to the **@ai-sdlc-planner** agent:

```
@ai-sdlc-planner Take User Story / Issue $ARGUMENTS. Pull the story from the configured
work item provider (read provider-config.md first), analyse the requirements
thoroughly, and surface any clarifying questions. Cap clarifying questions at **3**
when the story already has all of the following: at least two Given/When/Then
acceptance criteria, a non-empty Out of Scope section, and a non-empty Technical
Notes section. Reserve more questions for stories where these sections are missing
or contradictory. Do NOT proceed to planning until all ambiguities are resolved.
Use the story-intake skill.
```

**Wait** for the Planner to confirm requirements are fully understood.

If the human provides answers to clarifying questions, pass them to the Planner:

```
@ai-sdlc-planner The human provided these answers to the clarifying questions:
<answers>

Resolve the ambiguities with this information and confirm the requirements are complete.
```

Repeat until the Planner confirms all requirements are understood — no open ambiguities.

## Next Phase

Proceed to **Phase 2: Plan** — read and execute `commands/plan.md`.

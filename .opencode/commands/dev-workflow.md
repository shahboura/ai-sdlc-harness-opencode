---
description: "Execute full SDLC workflow for a work item: fetch → plan → TDD → review → security → PR → reconcile → metrics"
agent: planner
model: anthropic/claude-sonnet-4-5
---

# /dev-workflow

Execute the complete governed SDLC pipeline for a work item end-to-end.

## Usage
```
/dev-workflow <work-item-id>
```

## Arguments
- `work-item-id`: Provider work item ID (e.g., `PROJ-123`, `GH-456`)

## Workflow
1. **Fetch & Classify** — Retrieve work item, classify mode (full/quick)
2. **Intake** — Extract requirements, acceptance criteria
3. **Plan** — Create detailed plan with test intents, risk tiers, diagrams
4. **Human Gate: Approve Plan** — You approve/reject the plan
5. **Preflight** — Verify toolchain, create worktree
6. **Develop** — Proven-red TDD per task (developer agent)
7. **Human Gate: Approve Implementation** — You approve/reject
8. **Harden** — Security scan, edge cases
9. **Security Gate** — Conditional (threshold-based)
10. **Pre-PR Review** — Reviewer agent checks diff
11. **Human Gate: Approve Pre-PR** — You approve/reject
12. **Create PR** — `bin/harness create-pr` + `bin/harness push`
13. **Analyze Comments** — Optional: reviewer triages PR comments
14. **Reconcile** — Apply fixes, update contracts
15. **Metrics** — Record token spend, cycle time, gate outcomes

## Quick Mode
If work item has `Mode: quick` hint and no risk keywords:
- Skips plan step, single pre-PR gate
- Size caps: 80 lines / 5 files (configurable)
- `quick-recheck` escalates to full mode if diff exceeds caps

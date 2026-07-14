---
description: "Read-only dashboard: cursor, tasks, gates, flagged events per run"
agent: planner
model: anthropic/claude-sonnet-4-5
---

# /workflow-status

Read-only dashboard showing current pipeline state for one or all runs.

## Usage
```
/workflow-status [--run <run-id>]
```

## Options
- `--run <run-id>` — Show status for a specific run (omit for all runs)

## Output
- Current step and mode
- Task statuses (pending / in-progress / in-review / done)
- Gate states (pending / approved / rejected)
- Flagged events and metrics

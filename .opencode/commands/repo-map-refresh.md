---
description: "Regenerate the auto-generated codebase map the planner grounds its plans in"
agent: planner
model: anthropic/claude-sonnet-4-5
---

# /repo-map-refresh

Regenerate the codebase map used by the planner for grounding implementation plans.

## Usage
```
/repo-map-refresh [--repo-name <name>] [--repo <path>]
```

## Arguments
- `--repo-name <name>` — Name of the repo to map (omitted for all repos)
- `--repo <path>` — Path to the repo

## Workflow
1. `bin/harness repo-map-check --repo-name <n> --repo <path>` — Check staleness
2. Generate tiered map (structure → key files → details)
3. `bin/harness repo-map-stamp --repo-name <n> --repo <path>` — Stamp freshness

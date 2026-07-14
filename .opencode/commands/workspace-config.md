---
description: "Change one config section without re-running the interview"
agent: planner
model: anthropic/claude-sonnet-4-5
---

# /workspace-config

Modify workspace configuration sections without re-running the full setup interview.

## Usage
```
/workspace-config <section> [<key>=<value> ...]
```

## Sections
- `provider` — Change provider settings
- `repos` — Update repo paths or test commands
- `workflow` — Adjust pipeline knobs (review rounds, security thresholds)
- `naming` — Branch/commit naming conventions
- `permissions` — Update permission allowlists

## Examples
```
/workspace-config workflow review_rounds.max=3
/workspace-config naming branch_prefix=feat
```

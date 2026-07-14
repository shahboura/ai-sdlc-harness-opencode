---
description: "Shape a story's quality before building: analyze, refine, improve, groom"
agent: planner
model: anthropic/claude-sonnet-4-5
---

# /story-workflow

Analyze and shape a work item's quality before implementation begins.

## Usage
```
/story-workflow <command> <work-item-id>
```

## Commands
- `analyze <id>` — Analyze work item for clarity, completeness, testability
- `refine <id>` — Refine acceptance criteria, add edge cases
- `improve <id>` — Improve test intents, risk assessment
- `groom <id>` — Full grooming pass: dependencies, sizing, priority

## Arguments
- `command`: One of `analyze`, `refine`, `improve`, `groom`
- `work-item-id`: Provider work item ID

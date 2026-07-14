---
description: "Adopt a v2.x workspace: config carries over, run history stays archived"
agent: planner
model: anthropic/claude-sonnet-4-5
---

# /migrate-workspace

Migrate an existing v2.x workspace to the v3.0 format. Configuration carries over; run history stays archived in place.

## Usage
```
/migrate-workspace [--path <path>]
```

## Arguments
- `--path <path>` — Path to existing v2.x workspace (defaults to current directory)

## Workflow
1. `bin/harness migrate-detect` — Detect v2.x workspace structure
2. Review detected settings
3. `bin/harness migrate-extract` — Extract and convert configuration
4. Verify migrated workspace
5. Archive old run history

## Notes
- Old run data is not deleted — only archived
- Permission settings are migrated but may need review for opencode format

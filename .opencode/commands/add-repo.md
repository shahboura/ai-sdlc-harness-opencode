---
description: "Register one new repo into an already-bootstrapped workspace"
agent: planner
model: anthropic/claude-sonnet-4-5
---

# /add-repo

Register a new repository into an existing workspace without re-running the full setup.

## Usage
```
/add-repo --name <name> --path <path> [--test-cmd <cmd>]
```

## Arguments
- `--name <name>` — Short name for the repo
- `--path <path>` — Absolute path to the cloned repo
- `--test-cmd <cmd>` — Test command (auto-discovered if omitted)

## Workflow
1. `bin/harness discover --repo <path>` — Auto-detect toolchain
2. Review discovered settings
3. `bin/harness add-repo --name <n> --path <path> --test-cmd <cmd>`
4. `bin/harness init-verify` — Verification gate
5. `bin/harness init-finalize` — Finalize configuration

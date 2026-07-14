---
description: "One-time workspace setup: provider, repos, toolchain discovery, verification gate"
agent: planner
model: anthropic/claude-sonnet-4-5
---

# /init-workspace

One-time interview that bootstraps a workspace for the ai-sdlc-harness pipeline. Creates `.claude/context/`, discovers toolchain, configures provider, registers repos, and runs a verification gate.

## Usage
```
/init-workspace
```

## Workflow
1. **Provider selection** — GitHub, GitLab, ADO, Jira, or local-markdown
2. **Repo registration** — point to cloned repos, discover test commands
3. **Toolchain discovery** — detect language, test framework, build tools
4. **Verification gate** — every check must pass before proceeding
5. **Permission config** — writes `.claude/settings.json` with allowlist
6. **Bootstrap marker** — marks workspace as initialized

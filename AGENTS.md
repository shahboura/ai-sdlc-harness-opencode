# ai-sdlc-harness — Agent Instructions

## Overview

This repo implements a governed multi-agent SDLC pipeline. It runs inside **opencode** (not Claude Code). The pipeline drives a real engineering workflow: fetch → plan → proven-red TDD → review → security → PR → comment rounds → reconcile → metrics.

## Repository Structure

```
.opencode/              # opencode distribution (agents, commands, skills, plugins)
  agents/               # 3 agent shapes (planner, developer, reviewer)
  commands/             # 8 slash commands (/dev-workflow, /init-workspace, etc.)
  skills/               # 7 skills with step-by-step instructions
  plugins/              # TS bridge → Python hooks/guards.py
harness/                # Python core (CLI, workflow, state machine, gates, gitops)
pipeline/               # Pipeline manifests (manifest.yaml, task-fsm.yaml, surfaces.yaml)
config/defaults/        # Default config YAML files
hooks/                  # Python guard scripts (bridged by TS plugin, not ported)
bin/harness             # CLI wrapper: PYTHONPATH=. python -m harness "$@"
tests/                  # 606 unittest tests
tools/                  # Meta-tooling (budget_check, workspace generators)
```

## Agent Shapes

| Agent | Description | Permission Model |
|-------|-------------|-----------------|
| `planner` | Orchestrates workflow, spawns subagents, coordinates gates | Read/write under `ai/<run>/` and `.claude/context/`, can spawn developer/reviewer |
| `developer` | Writes tests + implementation (proven-red TDD) | Read/write in worktree, cannot spawn subagents |
| `reviewer` | Code review & security analysis (read-only) | Read-only, bash restricted to test runners and `/tmp` |

## Conventions

### Branch Naming
- `feat/<description>` — new features
- `fix/<description>` — bug fixes
- `chore/<description>` — maintenance, dependencies
- `docs/<description>` — documentation

### Commit Conventions
- `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:` prefixes
- imperative mood, no trailing period
- reference issue when applicable: `feat(core): add provider X (#42)`

### Style Guide
- **Python**: `harness/` follows PEP 8. Type hints required for all function signatures.
- **TypeScript**: `.opencode/plugins/` follows strict TS with `noEmit`.
- **Distribution**: npm package (`@shahboura/harness`) ships only `.opencode/` subdirs + README/LICENSE/CHANGELOG (256 kB, 62 files). The `files` field in `package.json` uses specific paths (not a broad `.opencode/` glob) to exclude node_modules.
- **Markdown**: All agent/skill/command files use frontmatter with `---` delimiters.
- **YAML**: `pipeline/` and `config/` use 2-space indentation.

### Testing
- All tests live in `tests/`. Run with: `PYTHONPATH=. python -m unittest discover -s tests -v`
- Tests are the source of truth. If a test fails, the code is wrong.
- `test_guards.py` tests the Python guard scripts in `hooks/`.

### Guards (Plugin-Enforced)
- **Git blocking**: Raw `git commit`, `git merge`, `git push` etc. are blocked. Use `bin/harness commit`, `bin/harness push` etc.
- **Path confinement**: Developers write only inside assigned worktree. Reviewers cannot write at all.
- **Red-proof**: `bin/harness verify-red` seals test files. Raw reads of `.redproof/` are blocked.
- **Spawn control**: Only the planner can spawn developer/reviewer subagents.

## Key Commands
- `bin/harness <verb>` — CLI wrapper for the Python core (~49 verbs)
- `npm pack --dry-run` — validate npm package before publish

## First-Time Setup
1. `opencode` (opens the CLI)
2. `/init-workspace` (one-time interview: provider, repos, toolchain)

## References
- See `.opencode/agents/` for agent-specific instructions
- See `.opencode/commands/` for slash command details
- See `pipeline/manifest.yaml` for the pipeline definition
- See `MIGRATION_PLAN.md` for the opencode migration plan

# Migration Plan: ai-sdlc-harness → opencode Distribution Model

## Executive Summary

This plan migrates the **ai-sdlc-harness** repository from a **Claude Code plugin** distribution model to the **opencode distribution model**, while establishing a **fork-sync-friendly workflow** that makes it trivial for downstream forks to stay current with upstream changes.

## Key Architectural Decisions (Confirmed)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Python core in npm?** | **No** — npm package contains only `.opencode/` (plugin) | Separation of concerns; Python distributed independently |
| **Python distribution** | **Bundled in repo root** (this is a fork of `MostAshraf/ai-sdlc-harness`) | `harness/`, `pipeline/`, `config/`, `bin/`, `hooks/`, `tests/`, `tools/` all live at repo root. No submodule needed. |
| **Versioning** | **Single version** in `versions.json` (authoritative) + duplicated in `package.json` | Solo maintainer, one repo, one release cadence |
| **npm package name** | `@shahboura/harness` | Your npm org; `@ai-sdlc` taken |
| **Postinstall** | **None** — assumes `harness` CLI in PATH | No bundling, no downloads, no PyPI |
| **Upstream sync** | Standard fork sync: `git remote add upstream` + `git pull upstream main` | This is a fork of `MostAshraf/ai-sdlc-harness` — standard GitHub fork workflow |
| **Plugin prototype** | Start **Week 1** (not Week 3) | Highest-risk component needs early validation |
| **Agent format** | `permission:` with `allow/deny/ask` (NOT deprecated `tools:`) | Aligns with modern opencode API |
| **opencode config location** | `./opencode.jsonc` at **project root** (NOT inside `.opencode/`) | opencode only discovers config at root or parent dirs |
| **Python bridge** | **Shell out** to `bin/harness` CLI via Bun's `$` shell API | No reimplementation of HMAC chain, ndjson, workspace resolution |
| **CLAUDE_PLUGIN_ROOT** | Replaced by **workspace root resolution** via plugin `directory` parameter | Global find-and-replace across all `.md` files |
| **Windows** | Git Bash only (current `harness.cmd`) | No native pwsh/cmd wrapper needed |

---

## 1. Current State Analysis

### Current Distribution Model (Claude Code Plugin)
```
ai-sdlc-harness/
├── .claude-plugin/
│   ├── plugin.json          # Plugin manifest (name, version, skills path)
│   └── marketplace.json     # Marketplace metadata
├── agents/                  # 3 agent shapes (planner, developer, reviewer)
├── skills/                  # 7 skills with SKILL.md + step files
├── hooks/                   # Claude Code hooks (guards.py + hooks.json)
├── pipeline/                # Pipeline manifests (manifest.yaml, task-fsm.yaml, surfaces.yaml)
├── config/defaults/         # 6 default config YAML files
├── harness/                 # Python core (CLI, workflow, state, gates, gitops, providers, migrate)
├── bin/                     # harness CLI wrapper (bash + cmd)
├── tools/                   # Meta-tooling (budget_check, workspace generators)
├── tests/                   # 606 unittest tests
├── README.md                # Documentation
├── CHANGELOG.md             # Changelog
├── LICENSE                  # MIT
└── .gitignore / .gitattributes
```

### Key Characteristics
- **Single-purpose**: Built exclusively for Claude Code plugin system
- **Distribution**: `git clone` + `claude --plugin-dir /path/to/repo`
- **Configuration**: `.claude/context/` (workspace) + `.claude/settings.json` (permissions)
- **Agents**: 3 fixed "shapes" defined in `agents/*.md` with tool grants
- **Skills**: Markdown-based with `SKILL.md` + step files in `skills/*/steps/`
- **Hooks**: Python-based guards in `hooks/guards.py` registered via `hooks/hooks.json`
- **CLI**: Python `harness` module with ~49 verbs, wrapped by `bin/harness`

---

## 2. Target State: opencode Distribution Model

### opencode Distribution Structure
```
ai-sdlc-harness-opencode/
├── .opencode/                      # ← npm package contents (@shahboura/harness)
│   ├── agents/                     # Agent definitions (markdown)
│   │   ├── planner.md
│   │   ├── developer.md
│   │   └── reviewer.md
│   ├── commands/                   # Custom slash commands (markdown)
│   │   ├── init-workspace.md
│   │   ├── dev-workflow.md
│   │   ├── story-workflow.md
│   │   ├── workflow-status.md
│   │   ├── workspace-config.md
│   │   ├── add-repo.md
│   │   ├── migrate-workspace.md
│   │   └── repo-map-refresh.md
│   ├── skills/                     # Skills (markdown + SKILL.md)
│   │   ├── dev-workflow/
│   │   ├── init-workspace/
│   │   ├── add-repo/
│   │   ├── migrate-workspace/
│   │   ├── workspace-config/
│   │   ├── workflow-status/
│   │   └── repo-map-refresh/
│   ├── plugins/                    # JS/TS plugins (for hooks)
│   │   └── harness-guards.ts       # Thin TS bridge → Python hooks/guards.py (not a port)
│   ├── tools/                      # Custom tools (optional)
│   └── package.json                # Plugin deps (for `bun install` in .opencode/)
├── opencode.jsonc                  # ← PROJECT ROOT config (opencode discovers this here)
├── tui.json                        # TUI settings (optional, alongside opencode.jsonc)
├── AGENTS.md                       # Agent instructions for opencode
├── package.json                    # npm package: @shahboura/harness
├── versions.json                   # Single version: { "version": "3.0.4" }
├── harness/                        # Python core (CLI, workflow, state, gates, gitops, providers, migrate)
├── pipeline/                       # Pipeline manifests (manifest.yaml, task-fsm.yaml, surfaces.yaml)
├── config/defaults/                # 6 default config YAML files
├── bin/harness                     # CLI wrapper (bash + cmd) — already exists
├── hooks/                          # Python guard scripts (bridged by TS plugin)
├── tests/                          # 606 unittest tests (unchanged)
├── tools/                          # Meta-tooling (unchanged)
├── scripts/
│   └── sync-upstream.sh            # Helper: git pull upstream (standard fork sync)
├── README.md                       # Updated for opencode
├── CHANGELOG.md
├── LICENSE
└── .gitignore / .gitattributes

# Key: opencode.jsonc is at PROJECT ROOT, NOT inside .opencode/
# Reason: opencode only discovers opencode.jsonc in root/git root, not in .opencode/
# Key: No `core/` submodule — this repo IS the fork, all files live at root
```

### Key Differences

| Aspect | Claude Code Plugin | opencode Distribution |
|--------|-------------------|----------------------|
| **Config** | `.claude-plugin/plugin.json` + `.claude/context/` | `./opencode.jsonc` (project root) + `.opencode/` subdirectories |
| **Agents** | `agents/*.md` (3 shapes) | `.opencode/agents/*.md` (same shapes, opencode format) |
| **Commands** | `/command` via plugin | `.opencode/commands/*.md` (slash commands) |
| **Skills** | `skills/*/SKILL.md` + steps | `.opencode/skills/*/SKILL.md` + steps |
| **Hooks** | Python `hooks/guards.py` + `hooks.json` | JS/TS plugin in `.opencode/plugins/` |
| **Distribution** | `claude --plugin-dir` | `opencode` auto-loads `.opencode/` |
| **Config Precedence** | Workspace-only | Remote → Global → Project → `.opencode/` |
| **Python Core** | Bundled in repo | **Bundled at root** (this IS the fork — `harness/`, `pipeline/`, etc. stay where they are) |
| **npm Package** | N/A | `@shahboura/harness` (only `.opencode/`) |
| **Versioning** | Single (git tag) | **Single version** in `versions.json` + git tag |

---

## 3. Migration Phases

### Phase 0: Plugin Prototype (Week 1 — Concurrent with Phase 1)
**Goal**: Validate that the opencode plugin API supports the 7 guard categories BEFORE building on top of it.

#### 0.1 Create Plugin Skeleton (Minimal Viable Plugin)
```typescript
// .opencode/plugins/harness-guards.ts
import type { Plugin } from "@opencode-ai/plugin"

export const HarnessGuardsPlugin: Plugin = async ({ project, client, $, directory, worktree }) => {
  return {
    "tool.execute.before": async (input, output) => {
      // Log all tool calls to verify hook fires
      console.log(`Tool: ${input.tool}, Agent: ${project.agent?.name}`);
      // Phase 0: just verify all 7 categories fire
    },
    "event": async ({ event }) => {
      // Log all events to verify what's available
      console.log(`Event: ${event.type}`);
    }
  }
}
```

#### 0.2 Validation Checklist
- [ ] `tool.execute.before` fires for bash, write, edit, read, grep, task tools
- [ ] `event` fires for `session.updated`, `tool.execute.after`
- [ ] Plugin receives `project.agent?.name` (for agent-aware guards)
- [ ] Plugin can shell out to `harness` CLI via `$`
- [ ] Plugin can read/write files (for ndjson/human-input capture)
- [ ] Bun TypeScript compilation works for `.ts` plugin
- [ ] Plugin loads correctly when `opencode` starts

**Exit criteria**: At least 6/7 items must pass to proceed to Phase 2-5. All items are effectively must-pass:
- **Items 1, 3, 4, 7**: Hook fires, agent name, shell-out, plugin load — fundamental to the bridge approach
- **Items 5, 6**: File I/O and Bun TS compilation — if these fail, the bridge architecture needs rethinking
- **Item 2**: Event capture — the only item with a known workaround (defer to harness CLI instead of events)
- If >1 item fails, escalate: opencode plugin API gap may require re-architecture.

#### 0.3 Risk Decision: Shell-Out vs Reimplement
**Decision: Shell out to `harness` CLI** (Bun's `$` shell API)
- PRO: No reimplementation of HMAC chain, ndjson, workspace resolution
- CON: ~100ms per invocation (acceptable for guard calls)
- CON: Depends on Python + harness CLI being in PATH

---

### Phase 1: Foundation & Configuration (Week 1)
**Goal**: Establish opencode config structure, project metadata, npm package, and fork configuration

#### 1.1 Create `./opencode.jsonc` (Project Root)
```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "name": "ai-sdlc-harness",
  "version": "3.0.4",
  "description": "Governed multi-agent SDLC pipeline for opencode",
  "agent": {
    "planner": {
      "description": "Planning & analysis agent — orchestrates the SDLC pipeline",
      "mode": "primary",
      "model": "anthropic/claude-sonnet-4-5",
      "permission": {
        "read": "allow",
        "grep": "allow",
        "glob": "allow",
        "write": { "ai/*": "allow", ".claude/context/*": "allow", "*": "deny" },
        "edit": { "ai/*": "allow", ".claude/context/*": "allow", "*": "deny" },
        "bash": "allow",
        "task": { "developer": "allow", "reviewer": "allow", "*": "deny" },
        "webfetch": "allow"
      }
    },
    "developer": {
      "description": "Implementation agent with proof-anchored TDD enforcement",
      "mode": "subagent",
      "hidden": true,
      "model": "anthropic/claude-sonnet-4-5",
      "permission": {
        "read": "allow",
        "grep": "allow",
        "glob": "allow",
        "write": "ask",
        "edit": "ask",
        "bash": "allow",
        "task": "deny"
      }
    },
    "reviewer": {
      "description": "Code review & security analysis agent (read-only)",
      "mode": "subagent",
      "hidden": true,
      "model": "anthropic/claude-sonnet-4-5",
      "permission": {
        "read": "allow",
        "grep": "allow",
        "glob": "allow",
        "write": "deny",
        "edit": "deny",
        "bash": { "*": "ask", "npm test*": "allow", "python -m unittest*": "allow", "cat /tmp/*": "allow" },
        "task": "deny"
      }
    }
  },
  "default_agent": "planner",
  "permission": {
    "bash": "ask",
    "edit": "ask",
    "write": "ask"
  },
  "plugin": ["@shahboura/harness"],
  // DEV MODE: Before npm publish, reference local path instead:
  // "plugin": ["./node_modules/@shahboura/harness"]
  // Or for monorepo dev without npm link:
  // "plugin": ["."]   // '.' loads .opencode/ from current directory
  "lsp": true,
  "formatter": true
}
```
**NOTE**: `opencode.jsonc` MUST be at project root — opencode discovers config by walking up from cwd to git root. Placing it inside `.opencode/` means it's never loaded.

#### 1.2 Create `./tui.json` (Project Root)
```json
{
  "$schema": "https://opencode.ai/tui.json",
  "theme": "tokyonight",
  "scroll_speed": 3,
  "mouse": true
}
```

#### 1.3 Create `AGENTS.md` (Root)
- Port key instructions from `README.md` and agent files
- Follow opencode AGENTS.md conventions (see opencode repo AGENTS.md)
- Include: branch naming, commit conventions, style guide, testing, type checking
- **CLAUDE_PLUGIN_ROOT references**: Replace with workspace root resolution
  - Agents must reference `bin/harness` (relative path) instead of `${CLAUDE_PLUGIN_ROOT}`

#### 1.4 Create `package.json` (Root — npm Package)
```json
{
  "name": "@shahboura/harness",
  "version": "3.0.4",
  "description": "Governed multi-agent SDLC pipeline for opencode",
  "author": "Mostafa Ashraf",
  "license": "MIT",
  "repository": {
    "type": "git",
    "url": "https://github.com/shahboura/ai-sdlc-harness-opencode.git"
  },
  "files": [
    ".opencode/",
    "README.md",
    "LICENSE",
    "CHANGELOG.md"
  ],
  "engines": {
    "node": ">=18.0.0"
  },
  "devDependencies": {
    "@opencode-ai/plugin": "^1.17.0",
    "typescript": "^5.0.0"
  }
}
```
**Changes from original plan**: Removed `peerDependencies` (opencode is not an npm-installable peer dep). Pinned `@opencode-ai/plugin` to `^1.17.0` (not `^1.0.0`). Removed unnecessary `scripts` and empty `bugs` section.

#### 1.5 Create `.opencode/package.json` (Plugin Dependencies)
```json
{
  "private": true,
  "dependencies": {
    "@opencode-ai/plugin": "^1.17.0"
  }
}
```
This is separate from the root `package.json` — it's used by `bun install` inside `.opencode/` for plugin type resolution.

#### 1.6 Create `versions.json` (Root — Single Source of Truth)
```json
{
  "version": "3.0.4",
  "core_ref": ""
}
```
- `version` = authoritative version for npm package, git tags, releases
- `core_ref` = pinned HEAD commit hash of upstream merge (updated on sync)
- On release: `version` bumped, git tag created, `core_ref` updated

#### 1.7 Create `bin/harness` Wrapper (No-op — Already Exists)
The `bin/harness` script already exists in the repo and handles Python path resolution:
```bash
#!/usr/bin/env bash
# Resolves the plugin venv; falls back to system python3/python
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/../.venv/bin/python"
...
exec env PYTHONPATH="$HERE/.." "$PY" -m harness "$@"
```
No changes needed — the bridge plugin shells out to `bin/harness` directly.

#### 1.8 Update `.gitignore`
```gitignore
# .opencode/ is committed (distribution)
# Only exclude node_modules within .opencode/
.opencode/node_modules/
.opencode/plugins/node_modules/

# Python venv
.venv/
```

#### 1.10 Global CLAUDE_PLUGIN_ROOT Replacement
Search and replace across ALL `.md` files:
- `${CLAUDE_PLUGIN_ROOT}` → workspace root (resolved at runtime)
- `CLAUDE_PLUGIN_ROOT` → `HARNESS_ROOT` or repo root path
- All agent files, skill files, step files reference the relative path `bin/harness`

---

### Phase 1.5: Upstream Sync Helper (Week 1)
**Goal**: Standard fork sync script (no submodule — this IS the fork)

#### 1.5.1 Add Upstream Remote (One-Time)
```bash
git remote add upstream https://github.com/MostAshraf/ai-sdlc-harness.git
```

#### 1.5.2 Create `scripts/sync-upstream.sh`
```bash
#!/usr/bin/env bash
# Sync from upstream MostAshraf/ai-sdlc-harness
# Standard fork sync — no submodule involved
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "=== Fetching upstream ==="
git fetch upstream

echo "=== Current branch ==="
BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "On branch: $BRANCH"

echo "=== Merging upstream changes ==="
git merge upstream/main --no-edit || {
  echo "Merge conflict detected. Resolve conflicts, then run:"
  echo "  git commit && git push origin $BRANCH"
  exit 1
}

echo "=== Updating versions.json (core_ref) ==="
CORE_SHA=$(git rev-parse HEAD)
CURRENT_VERSION=$(node -e "console.log(require('./versions.json').version)")
cat > versions.json <<EOF
{
  "version": "$CURRENT_VERSION",
  "core_ref": "$CORE_SHA"
}
EOF

git add versions.json
git commit --amend --no-edit

echo "=== Done. Push: git push origin $BRANCH ==="
```

---

### Phase 2: Agent Migration (Week 1-2)
**Goal**: Port 3 agent shapes to opencode agent format with modern permission API

#### 2.1 Agent Format Differences
| Claude Code Agent | opencode Agent (Modern) |
|-------------------|------------------------|
| Tool grants in frontmatter | `permission:` with `"allow"`, `"deny"`, `"ask"` (NOT deprecated `tools:`) |
| `harness-mode:` headers | Spawn control via `permission.task` globs |
| Shape-based (planner/developer/reviewer) | Named agents with `mode: primary|subagent` |
| No hidden flag | `hidden: true` for internal subagents |

#### 2.2 Create `.opencode/agents/planner.md`
```markdown
---
description: "Planning & analysis agent for SDLC workflow"
mode: "primary"
model: "anthropic/claude-sonnet-4-5"
permission:
  read: allow
  grep: allow
  glob: allow
  write:
    "ai/*": "allow"
    ".claude/context/*": "allow"
    "*": "deny"
  edit:
    "ai/*": "allow"
    ".claude/context/*": "allow"
    "*": "deny"
  bash: allow
  task:
    "developer": "allow"
    "reviewer": "allow"
    "*": "deny"
  webfetch: allow
---

# Planner Agent

You are the **planner** agent for the ai-sdlc-harness SDLC pipeline.

## Responsibilities
- Intake: Fetch and classify work items from providers (GitHub, GitLab, ADO, Jira, local markdown)
- Plan: Create detailed implementation plans with test intents, risk tiers, edge cases
- Repo Map: Generate and refresh codebase maps for grounding

## Path Confinement (Plugin-Enforced)
- Writes allowed only under `ai/<run>/` and `.claude/context/`
- Never write to repo source files directly
- All git operations via `bin/harness` CLI verbs
- State managed via `bin/harness` state machine

## Workflow
1. Receive work item via `/dev-workflow <id>` or `/story-workflow analyze <id>`
2. Run intake → plan → (human gate) → preflight
3. Spawn developer via `task` tool (spawn prompt should ideally include `harness-mode: develop` for documentation; **note: opencode plugin cannot validate these headers** — spawn permission is enforced at agent level via `permission.task` globs, not prompt content)
4. Spawn reviewer via `task` tool (same advisory header pattern)
5. Coordinate review, reconciliation, and gates
```

#### 2.3 Create `.opencode/agents/developer.md`
```markdown
---
description: "Implementation agent with proof-anchored TDD enforcement"
mode: "subagent"
hidden: true
model: "anthropic/claude-sonnet-4-5"
permission:
  read: allow
  grep: allow
  glob: allow
  write: ask
  edit: ask
  bash: allow
  task: deny
---

# Developer Agent

You are the **developer** agent for the ai-sdlc-harness SDLC pipeline.

## Responsibilities
- Write failing tests first (proven-red TDD)
- Implement code to make tests pass
- Harden implementation (security, edge cases)
- Apply pre-PR fixes from reviewer feedback

## Path Confinement (Plugin-Enforced)
- Writes only inside assigned task worktree (enforced by harness guards)
- Non-test paths are blocked until `harness verify-red` seals red-proof

## TDD Enforcement (Plugin-Enforced)
1. Write tests first — non-test writes blocked until `bin/harness verify-red` seals red-proof
2. `bin/harness verify-red` runs tests, seals chained red-proof + SHA-locks test files
3. Implement until green; checkpoint via `bin/harness commit`
4. Completion requires `verify-green` + red-proof SHA verification
5. Test revisions require `bin/harness verify-red --revise --reason "..."` (flagged event)

## Worktree Isolation
- Each task runs in dedicated git worktree: `bin/harness worktree-add --task T1`
- Worktree removed on task completion: `bin/harness worktree-remove`
```

#### 2.4 Create `.opencode/agents/reviewer.md`
```markdown
---
description: "Code review & security analysis agent (read-only)"
mode: "subagent"
hidden: true
model: "anthropic/claude-sonnet-4-5"
permission:
  read: allow
  grep: allow
  glob: allow
  write: deny
  edit: deny
  bash:
    "*": "ask"
    "npm test*": "allow"
    "python -m unittest*": "allow"
    "cat /tmp/*": "allow"
  task: deny
---

# Reviewer Agent

You are the **reviewer** agent for the ai-sdlc-harness SDLC pipeline.

## Responsibilities
- Review implementation diffs independently (re-run build + tests)
- Security scanning (configured scan commands)
- Pre-PR review (completeness, contracts, docs)
- PR comment analysis & triage
- Request triage (ad-hoc human requests during runs)

## Path Confinement (Plugin-Enforced)
- No write/edit access — strictly read-only
- Bash commands restricted: test runners and `/tmp` reads allowed; general writes denied
- `bin/harness` verbs allowed for state queries

## Review Modes
- `review`: Post-implementation code review
- `pre-pr`: Pre-PR readiness check
- `analyze-comments`: PR comment triage
- `request-triage`: Ad-hoc human request classification

## Verdict Format
Output structured verdict captured by hooks:
```
VERDICT: APPROVED
# or
VERDICT: CHANGES_REQUESTED
1. Finding description
2. Finding description
```

---

### Phase 3: Command Migration (Week 2)
**Goal**: Convert 8 slash commands to opencode command format

#### 3.1 Command Format
opencode commands are markdown files in `.opencode/commands/` with frontmatter:
```markdown
---
description: "One-line description"
agent: "planner"  # or "developer", "reviewer", "build"
model: "anthropic/claude-sonnet-4-5"
---

# Command Name

Command description and usage instructions.

## Usage
```
/command-name <args>
```

## Implementation
The command invokes the harness CLI or spawns agents.
```

#### 3.2 Commands to Migrate
| Current Command | opencode Command File | Agent |
|-----------------|----------------------|-------|
| `/init-workspace` | `.opencode/commands/init-workspace.md` | planner |
| `/dev-workflow <id>` | `.opencode/commands/dev-workflow.md` | planner |
| `/story-workflow <cmd> <id>` | `.opencode/commands/story-workflow.md` | planner |
| `/workflow-status` | `.opencode/commands/workflow-status.md` | planner |
| `/workspace-config` | `.opencode/commands/workspace-config.md` | planner |
| `/add-repo` | `.opencode/commands/add-repo.md` | planner |
| `/migrate-workspace` | `.opencode/commands/migrate-workspace.md` | planner |
| `/repo-map-refresh` | `.opencode/commands/repo-map-refresh.md` | planner |

#### 3.3 Example: `.opencode/commands/dev-workflow.md`
```markdown
---
description: "Execute full SDLC workflow for a work item"
agent: planner
model: anthropic/claude-sonnet-4-5
---

# /dev-workflow

Execute the complete governed SDLC pipeline for a work item: fetch → plan → proven-red TDD → review → security → PR → reconcile → metrics.

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
12. **Create PR** — `harness create-pr` + `harness push`
13. **Analyze Comments** — Optional: reviewer triages PR comments
14. **Reconcile** — Apply fixes, update contracts
15. **Metrics** — Record token spend, cycle time, gate outcomes

## Implementation
The planner agent orchestrates by:
1. Calling `harness fetch --work-item <id>`
2. Spawning developer/reviewer subagents via `Task` tool (ideal spawn prompt includes `harness-mode:` headers for traceability; **plugin cannot validate these headers** — agent-level `permission.task` globs control spawn authorization)
3. Calling `harness` verbs for state transitions, git ops, gates
4. Presenting human gates for your decisions

## Quick Mode
If work item has `Mode: quick` hint and no risk keywords:
- Skips plan step
- Single pre-PR gate
- Size caps: 80 lines / 5 files (configurable)
- `quick-recheck` escalates to full mode if diff exceeds caps
```

---

### Phase 4: Skills Migration (Week 2-3)
**Goal**: Move skills to `.opencode/skills/` with opencode-compatible structure

#### 4.1 Skill Structure Mapping
```
Current: skills/dev-workflow/
  SKILL.md
  steps/
    intake.md, plan.md, develop.md, ...

Target: .opencode/skills/dev-workflow/
  SKILL.md
  steps/
    intake.md, plan.md, develop.md, ...
```

#### 4.2 SKILL.md Format (opencode compatible)
```markdown
---
name: "dev-workflow"
description: "End-to-end SDLC workflow orchestration"
version: "3.0.0"
author: "Mostafa Ashraf"
---

# Dev Workflow Skill

This skill provides the step-by-step procedures for the `/dev-workflow` command.

## Steps
- `intake` — Fetch and classify work item
- `plan` — Create implementation plan
- `preflight` — Verify toolchain, create worktree
- `develop` — Proven-red TDD implementation
- `harden` — Security scan and hardening
- `pre-pr` — Pre-PR review
- `create-pr` — Create pull request
- `reconcile` — Apply fixes, update contracts
- `metrics` — Record run metrics

## Agent Shapes
- `planner` — Orchestrates workflow, spawns subagents
- `developer` — Implements tasks in worktree
- `reviewer` — Reviews code, runs security scans

## Configuration
References `config/defaults/workflow.yaml` for:
- `review_rounds.max` (default: 5)
- `security.gate_threshold` (default: medium)
- `quick_mode.size_caps` (lines: 80, files: 5)
```

#### 4.3 Skills to Migrate (7 skills)
1. `dev-workflow` → `.opencode/skills/dev-workflow/`
2. `init-workspace` → `.opencode/skills/init-workspace/`
3. `add-repo` → `.opencode/skills/add-repo/`
4. `migrate-workspace` → `.opencode/skills/migrate-workspace/`
5. `workspace-config` → `.opencode/skills/workspace-config/`
6. `workflow-status` → `.opencode/skills/workflow-status/`
7. `repo-map-refresh` → `.opencode/skills/repo-map-refresh/`

**Note**: Step files (`steps/*.md`) can be copied as-is — they're markdown instructions read by agents at spawn time.

---

### Phase 5: Hooks → Plugin Bridge (Week 3)
**Goal**: Create a thin TypeScript bridge that delegates guard decisions to the existing Python `hooks/guards.py`, keeping all guard logic in Python where it belongs.

#### 5.1 Why a Bridge Instead of a Port?

| Approach | Cost | Risk | Test Impact |
|----------|------|------|-------------|
| **Full TS port** of `hooks/guards.py` | ~200 lines, re-debug guard logic | Medium — subtle behavior differences | Tests for guards need new harness |
| **Thin TS bridge** → existing Python guards | ~50 lines, no logic change | Very low — Python stays Python | **All 606 tests pass unchanged** |
| **Hybrid** (port some, bridge some) | ~100 lines, confusing architecture | Medium — split responsibility | Partial test breakage |

**Decision: Thin TS bridge.** The TypeScript plugin only:
1. Receives hook context from opencode (`tool.execute.before`, `event`)
2. Serializes relevant context to JSON
3. Shells out to Python `hooks/guards.py` via Bun's `$` API
4. Returns the allow/deny decision

No guard logic is rewritten — the Python `hooks/guards.py` stays at `hooks/guards.py` in the repo root, untouched.

#### 5.2 Plugin Structure
```
.opencode/plugins/
├── harness-guards.ts        # Main plugin entry point (THIN BRIDGE)
│                            # Houses: tool.execute.before → shell to Python guard
│                            #         event → light TS capture for opencode events
└── lib/
    ├── workspace.ts          # Workspace root resolution
    └── harness-cli.ts        # Shell-out helpers to bin/harness
```

**No `guards/` subdirectory** — the individual guard implementations (`bash-guard.ts`, `path-guard.ts`, `spawn-guard.ts`) don't exist as TS files. The Python `hooks/guards.py` is the single source of guard truth.

#### 5.3 Guard Bridging Matrix

| Python Guard | opencode Hook | Bridge Strategy |
|--------------|---------------|-----------------|
| `bash` | `tool.execute.before` | 🔗 Serialize `{ tool: "bash", command, agentName, worktree }` → `$ hooks/guards.py check-bash` → return boolean |
| `write` | `tool.execute.before` | 🔗 Serialize `{ tool: "write", filePath, agentName }` → `$ hooks/guards.py check-write` → return boolean |
| `read` | `tool.execute.before` | 🔗 Serialize `{ tool: "read", filePath, agentName }` → `$ hooks/guards.py check-read` → return boolean |
| `spawn` | `permission.task` globs + bridge | Agent-level enforcement via `permission.task` globs (always). Optional bridge call for logging: `$ hooks/guards.py log-spawn { fromAgent, toAgent }` |
| `prompt_capture` | `event` (session.updated) | ⚠️ Still fragile — opencode doesn't expose `UserPromptSubmit`. Bridge may pass session events to Python: `$ hooks/guards.py capture-event { type, data }` |
| `verdict_capture` | `tool.execute.after` | 🔗 Inspect tool output for verdict pattern, pass to Python: `$ hooks/guards.py capture-verdict { verdict, agentName }` |
| `stop_capture` | `event` (session.updated) | ⚠️ GAP — no `SubagentStop`. Mitigation: token accounting from `harness` CLI verbs, not plugin events. |

#### 5.4 Plugin Architecture: Bridge Implementation
```typescript
// .opencode/plugins/harness-guards.ts
import type { Plugin } from "@opencode-ai/plugin"
import { $ } from "bun"

// Path to Python guards (at repo root)
function guardsPy(directory: string): string {
  return `${directory}/hooks/guards.py`
}

export const HarnessGuardsPlugin: Plugin = async ({ project, client, $, directory }) => {
  return {
    "tool.execute.before": async (input) => {
      // Bridge all guard decisions to Python hooks/guards.py
      const context = {
        tool: input.tool,
        command: input.args?.command,
        filePath: input.args?.filePath,
        agentName: project.agent?.name || "direct-user"
      }
      const result = await $`python3 ${guardsPy(directory)} check --context ${JSON.stringify(context)}`.quiet()
      const decision = JSON.parse(result.text())
      if (decision.block) {
        return { content: `Blocked by harness guard: ${decision.reason}`, blocking: true }
      }
    },
    "event": async ({ event }) => {
      // Light TS capture for opencode-specific events (no Python equivalent)
      if (event.type === "session.updated") {
        // Minimal token tracking — defer to harness CLI for accurate accounting
      }
    }
  }
}
```

#### 5.5 Guard Invocation Protocol
The Python guard script (`hooks/guards.py`) receives JSON context on stdin and returns JSON decisions:
```
Input:  { "tool": "bash", "command": "git commit -m 'foo'", "agentName": "developer" }
Output: { "block": true, "reason": "Raw git commit blocked. Use: bin/harness commit" }

Input:  { "tool": "write", "filePath": "ai/run-123/plan.md", "agentName": "planner" }
Output: { "block": false }

Input:  { "tool": "read", "filePath": ".redproof/test_foo.md", "agentName": "developer" }
Output: { "block": true, "reason": "Red-proof files are read-only after sealing" }
```

The Python script is extended with a `check` verb that dispatches to the existing guard logic by `input.tool`. No existing guard logic is rewritten — just wrapped in a JSON-RPC-style handler.

#### 5.6 Spawn Control
The spawn guard **cannot** validate `harness-mode:` headers in opencode (those headers are in the Task tool description, not exposed to the plugin). Permission is configured at the agent level via `permission.task` globs. The Python guard is called for optional logging only:
```yaml
# In planner agent frontmatter:
permission:
  task:
    "developer": "allow"
    "reviewer": "allow"
    "*": "deny"
```

#### 5.7 Event Capture Strategy
Some capture still needs TS because the events are opencode-specific (no Python equivalent):
```typescript
// Verdict capture — bridge to Python for storage
export async function captureVerdict(verdict: string, agentName: string, directory: string) {
  await $`python3 ${directory}/hooks/guards.py capture-verdict \
    --data ${JSON.stringify({ verdict, agentName })}`.quiet()
}

// Token accounting — defer to harness CLI
// No SubagentStop event in opencode; use harness CLI for accurate per-subagent tokens
```

#### 5.8 Dependencies
- `.opencode/package.json` with `@opencode-ai/plugin` ^1.17.0 (Types only)
- Python `hooks/guards.py` lives at `hooks/guards.py` (repo root, unchanged)
- No additional npm dependencies — Bun's built-in `$` shell API is sufficient
- No TypeScript guard implementation — all guard logic stays in Python

#### 5.9 npm Package Integration
- Plugin lives in `.opencode/plugins/harness-guards.ts` (inside npm package, ~50 lines)
- Python guards stay at `hooks/guards.py` (repo root, outside npm package)
- When npm package is installed standalone (without the full repo), guards won't be available — document this limitation

---

### Phase 6: Configuration & Defaults (Week 3)
**Goal**: Ensure config/defaults work with opencode config precedence

#### 6.1 Config Precedence in opencode
1. Remote (`.well-known/opencode`) — org defaults
2. Global (`~/.config/opencode/opencode.json`) — user prefs
3. Project (`opencode.jsonc` in repo root) — project settings
4. `.opencode/` directory — agents, commands, skills, plugins
5. Inline (`OPENCODE_CONFIG_CONTENT`) — runtime overrides

#### 6.2 Strategy
- Keep `config/defaults/` as **reference defaults** (documentation)
- Project `opencode.jsonc` sets project-level overrides
- Workspace config (`.claude/context/`) remains for harness runtime
- Document: "Harness runtime config lives in `.claude/context/`; opencode config in `opencode.jsonc`"

#### 6.3 Config Files to Document
| File | Purpose | opencode Equivalent |
|------|---------|---------------------|
| `config/defaults/workflow.yaml` | Pipeline knobs | Document in README |
| `config/defaults/naming.yaml` | Branch/commit naming | Document in README |
| `config/defaults/review-policy.yaml` | Review thresholds | Document in README |
| `config/defaults/quick-mode.yaml` | Quick mode caps | Document in README |
| `config/defaults/status-mapping.yaml` | Provider status mapping | Document in README |
| `config/defaults/subagent-models.yaml` | Model assignments | Agent frontmatter in `.opencode/agents/` |

---

### Phase 7: Documentation & Distribution (Week 3-4)
**Goal**: Update README, create distribution docs, verify install flow

#### 7.1 Update README.md
- Replace "Install" section with opencode instructions
- Add "Quick Start with opencode" section
- Document agent shapes, commands, skills
- Link to opencode docs

#### 7.2 New Install Instructions
```markdown
## Install (opencode)

### Option 1: npm Global (Recommended)
```sh
npm install -g @shahboura/harness
cd your-project
opencode
# Run /init-workspace inside opencode
```

### Option 2: Clone & Run (Development)
```sh
git clone --recursive https://github.com/shahboura/ai-sdlc-harness-opencode.git
cd ai-sdlc-harness-opencode
opencode
# Run /init-workspace inside opencode
```

### Option 3: Per-Project
```sh
# In your project root
npm install @shahboura/harness --save-dev
# Add to opencode.jsonc:
# { "plugin": ["./node_modules/@shahboura/harness"] }
opencode
```

**Python Core**: Requires Python 3.10+ with `harness` package importable. Already bundled in the repo at `harness/`:
- The existing `bin/harness` script handles `PYTHONPATH` automatically
- For standalone npm install: ensure `harness` module is available on `PYTHONPATH` or install via `pip install -e .` from a clone

#### 7.3 Create `DISTRIBUTION.md`
Document the distribution model, versioning, and fork-sync strategy.

#### 7.4 Create `CONTRIBUTING.md`
Contribution guide for upstream PRs.

---

### Phase 8: Testing & Validation (Week 4)
**Goal**: Verify end-to-end workflow in opencode

#### 8.1 Test Checklist
- [ ] `opencode` starts without errors (smoke test)
- [ ] Plugin prototype (Phase 0) validates all 7 hook categories fire
- [ ] `/init-workspace` runs interview, creates `.claude/context/`, venv
- [ ] `/dev-workflow <id>` executes full pipeline (end-to-end with local-markdown provider)
- [ ] Agents spawn with correct tool grants and permission restrictions
- [ ] Plugin enforces guards:
  - [ ] Git blocking: `git commit` is blocked, `bin/harness commit` allowed
  - [ ] Path confinement: developer writes restricted to worktree, reviewer writes denied
  - [ ] Spawn control: planner can spawn developer/reviewer, developer cannot spawn
  - [ ] Red-proof: `bin/harness verify-red` works, raw `.redproof/` reads blocked
- [ ] State machine works (`bin/harness` CLI verbs)
- [ ] TDD red-proof flow works (`bin/harness verify-red`)
- [ ] Human gates capture input correctly
- [ ] PR creation and reconciliation work
- [ ] All 606 tests pass: `PYTHONPATH=. python -m unittest discover -s tests -v` (from repo root)
- [ ] `npm pack --dry-run` succeeds, only includes `.opencode/` + `README.md` + `LICENSE`
- [ ] CI grep: `grep -r CLAUDE_PLUGIN_ROOT . --include='*.md' --include='*.py' --include='*.ts' --include='*.yaml'` returns empty
- [ ] All tests referencing old paths updated (see "Test Migration Workstream" below)

#### 8.2 CI/CD Updates (`.github/workflows/ci.yml`)
```yaml
# Add these jobs to existing CI pipeline:
jobs:
  plugin-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
      - name: Install plugins deps
        run: |
          cd .opencode && bun install
      - name: Type-check plugin bridge
        run: |
          cd .opencode && bunx tsc --noEmit
      - name: Validate npm package
        run: npm pack --dry-run

  python-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Run harness tests
        run: |
          PYTHONPATH=. python -m unittest discover -s tests -v

  claude-plugin-root-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check for CLAUDE_PLUGIN_ROOT remnants
        run: |
          FOUND=$(grep -r CLAUDE_PLUGIN_ROOT . --include='*.md' --include='*.py' --include='*.ts' --include='*.yaml' --include='*.yml' || true)
          if [ -n "$FOUND" ]; then
            echo "ERROR: CLAUDE_PLUGIN_ROOT still referenced:"
            echo "$FOUND"
            exit 1
          fi
```

#### 8.3 Test Migration Workstream (Cross-Cutting, Week 1-4)
**Goal**: Ensure all 606 tests pass with the new file structure. Keep test logic identical — only update path references that changed due to restructuring.

**Test audit (Week 1, concurrent with Phase 1):**
- [ ] `test_guards.py`: References `hooks/guards.py` — still valid since guards stay in Python at `hooks/`. No change needed.
- [ ] `test_schema.py`: References `.claude-plugin/plugin.json` — update to `versions.json`
- [ ] `test_invocation_consistency.py`: Iterates `agents/`, `skills/` — update to `.opencode/agents/`, `.opencode/skills/`
- [ ] `test_plan_contract.py`: References root `agents/`, `skills/` — update to `.opencode/` paths
- [ ] `test_budget.py`: Creates temp dirs for test fixtures — no change needed
- [ ] Any other test referencing old paths: grep for `.claude-plugin`, `hooks/`, root-level `agents/`, `skills/`

**Updates (Week 2-3, concurrent with Phase 2-5):**
- Apply path updates as each phase completes (e.g., update `test_invocation_consistency.py` when agents/skills are moved)
- Run full test suite after each phase: `PYTHONPATH=. python -m unittest discover -s tests -v`

**Validation (Week 4, Phase 8):**
- Full test suite passes: all 606 tests green
- New integration test: plugin bridge → Python guard → allow/deny (optional)

---

## 4. Fork-Sync Strategy

### Goal
Make it trivial for downstream forks to:
1. Stay current with upstream changes
2. Maintain their customizations
3. Contribute back upstream

### 4.1 Repository Structure for Fork-Friendliness

```
shahboura/ai-sdlc-harness-opencode/          ← YOUR REPO (upstream for downstream)
├── .opencode/                               ← npm package contents (committed, versioned)
│   ├── agents/
│   ├── commands/
│   ├── skills/
│   └── plugins/
├── package.json                             ← @shahboura/harness
├── versions.json                            ← Single version: { "version": "3.0.4" }
├── scripts/sync-upstream.sh                 ← Helper: git fetch upstream + merge
├── AGENTS.md                                ← Agent instructions
├── DISTRIBUTION.md                          ← Fork sync guide
├── CONTRIBUTING.md                          ← Contribution guide
├── harness/                                 ← Python core (unchanged)
├── pipeline/                                ← Pipeline manifests (unchanged)
├── hooks/                                   ← Python guards (unchanged)
├── config/                                  ← Config defaults (unchanged)
├── tests/                                   ← 606 tests (unchanged)
├── tools/                                   ← Meta-tooling (unchanged)
└── README.md
```

### 4.2 Fork Sync Workflow

#### For You (Syncing from MostAshraf Upstream)
```bash
# One-time: add upstream remote
git remote add upstream https://github.com/MostAshraf/ai-sdlc-harness.git

# Regular sync:
git fetch upstream
git merge upstream/main
# Test integration
PYTHONPATH=. python -m unittest discover -s tests -v
# Update versions.json with new HEAD
CORE_SHA=$(git rev-parse HEAD)
node -e "let v=require('./versions.json'); v.core_ref='$CORE_SHA'; require('fs').writeFileSync('versions.json', JSON.stringify(v,null,2)+'\n')"
git add versions.json
git commit -m "chore: sync upstream changes ($CORE_SHA)"
git push
```

#### For Downstream Fork Maintainers (One-time Setup)
```bash
# 1. Fork shahboura/ai-sdlc-harness-opencode on GitHub
# 2. Clone your fork
git clone https://github.com/YOUR-ORG/ai-sdlc-harness-opencode.git
cd ai-sdlc-harness-opencode

# 3. Add upstream remote (your repo)
git remote add upstream https://github.com/shahboura/ai-sdlc-harness-opencode.git

# 4. Create customization branch
git checkout -b my-customizations

# 5. Make changes to .opencode/agents/, .opencode/commands/, .opencode/skills/
#    Update package.json name: "@your-org/harness"
#    Version: "3.0.4-yourorg.1" (semver + build metadata)

# 6. Test locally
npm pack  # Creates @your-org/harness-3.0.4-yourorg.1.tgz
npm install -g ./@your-org-harness-3.0.4-yourorg.1.tgz
opencode  # Test your customizations

# 7. Publish to npm (your org scope)
npm publish --access public
```

#### For Downstream Fork Maintainers (Regular Sync)
```bash
# 1. Fetch upstream (your repo)
git fetch upstream

# 2. Rebase customizations onto latest upstream
git rebase upstream/main my-customizations
# OR merge:
git merge upstream/main

# 3. Resolve conflicts (usually only in .opencode/ or if upstream changed harness/)
# 4. Bump version: npm version prerelease --preid=yourorg
# 5. Publish
npm publish
```

#### For End Users (Consuming Downstream Fork)
```bash
# Global
npm install -g @your-org/harness
# Or per-project
npm install @your-org/harness
```

### 4.3 Protected Paths (Minimize Conflicts)
| Path | Conflict Risk | Strategy |
|------|---------------|----------|
| `.opencode/agents/` | Medium | Fork maintains custom agents; rebase |
| `.opencode/commands/` | Medium | Fork maintains custom commands; rebase |
| `.opencode/skills/` | Medium | Fork maintains custom skills; rebase |
| `.opencode/plugins/` | Low | Fork adds plugins; upstream adds hooks |
| `harness/` (Python core) | Medium | Upstream changes; fork may modify |
| `package.json` | Low | Fork changes name/version only |
| `versions.json` | Low | Auto-updated on sync |

### 4.4 Versioning Strategy
- **Single version** in `versions.json`: `{ "version": "3.0.4" }`
- `package.json` version = `versions.json` version
- Git tag = `v3.0.4`
- Upstream commit pinned in `versions.json` (`"core_ref": "abc123"`)
- Downstream forks: `3.0.4-yourorg.1` (semver build metadata)

### 4.5 Upstream Contribution Flow
```bash
# In your fork (shahboura/ai-sdlc-harness-opencode)
git checkout -b feat/my-new-skill
# Make changes to .opencode/skills/
git commit -m "feat(skill): add my-custom-skill"
git push origin feat/my-new-skill
# Open PR to shahboura/ai-sdlc-harness-opencode
```

---

## 5. Migration Checklist

### Phase 1: Foundation
- [ ] Create `./opencode.jsonc` (project root)
- [ ] Create `./tui.json` (project root)
- [ ] Create `AGENTS.md` (root)
- [ ] Create `package.json` (root npm package)
- [ ] Create `.opencode/package.json` (plugin deps)
- [ ] Create `.opencode/tsconfig.json` (TS config)
- [ ] Create `versions.json` (single version source)
- [ ] Add upstream remote: `git remote add upstream https://github.com/MostAshraf/ai-sdlc-harness.git`
- [ ] Create `scripts/sync-upstream.sh`
- [ ] Update `.gitignore` (add `.opencode/node_modules/`)
- [ ] Global `CLAUDE_PLUGIN_ROOT` replacement across all `.md` files

### Phase 2: Agents
- [ ] Create `.opencode/agents/planner.md`
- [ ] Create `.opencode/agents/developer.md`
- [ ] Create `.opencode/agents/reviewer.md`
- [ ] Verify tool grants match harness guard expectations

### Phase 3: Commands
- [ ] Create `.opencode/commands/init-workspace.md`
- [ ] Create `.opencode/commands/dev-workflow.md`
- [ ] Create `.opencode/commands/story-workflow.md`
- [ ] Create `.opencode/commands/workflow-status.md`
- [ ] Create `.opencode/commands/workspace-config.md`
- [ ] Create `.opencode/commands/add-repo.md`
- [ ] Create `.opencode/commands/migrate-workspace.md`
- [ ] Create `.opencode/commands/repo-map-refresh.md`

### Phase 4: Skills
- [ ] Copy `skills/dev-workflow/` → `.opencode/skills/dev-workflow/`
- [ ] Copy `skills/init-workspace/` → `.opencode/skills/init-workspace/`
- [ ] Copy `skills/add-repo/` → `.opencode/skills/add-repo/`
- [ ] Copy `skills/migrate-workspace/` → `.opencode/skills/migrate-workspace/`
- [ ] Copy `skills/workspace-config/` → `.opencode/skills/workspace-config/`
- [ ] Copy `skills/workflow-status/` → `.opencode/skills/workflow-status/`
- [ ] Copy `skills/repo-map-refresh/` → `.opencode/skills/repo-map-refresh/`
- [ ] Update each `SKILL.md` with opencode frontmatter

### Phase 5: Hooks → Plugin Bridge
- [ ] Create `.opencode/plugins/harness-guards.ts` (thin TS bridge)
- [ ] Implement `tool.execute.before` → JSON serialize context → shell to `core/hooks/guards.py`
- [ ] Implement `event` capture (light TS, no Python port)
- [ ] Add `check` verb to Python `hooks/guards.py` (JSON-RPC wrapper around existing guard logic)
- [ ] Add `capture-verdict` verb to Python `hooks/guards.py`
- [ ] Add `capture-event` verb to Python `hooks/guards.py` (optional)
- [ ] Configure spawn control via `permission.task` globs (agent frontmatter, not plugin)
- [ ] Create `.opencode/package.json` with `@opencode-ai/plugin` types
- [ ] Verify: all 606 tests still pass (guards tested directly via Python, not through TS bridge)

### Phase 6: Config & Defaults
- [ ] Document config precedence in README
- [ ] Verify `config/defaults/` referenced correctly
- [ ] Update `harness` CLI to read opencode config where needed

### Phase 7: Documentation
- [ ] Update `README.md` with opencode install instructions
- [ ] Create `DISTRIBUTION.md` with fork-sync guide
- [ ] Update `CHANGELOG.md` with migration entry
- [ ] Create `CONTRIBUTING.md` if missing

### Phase 8: Testing
- [ ] `opencode` starts cleanly
- [ ] `/init-workspace` completes successfully
- [ ] `/dev-workflow` runs end-to-end (test with local-markdown provider)
- [ ] Guards enforce: git blocking, path confinement, spawn validation
- [ ] State machine transitions work
- [ ] TDD red-proof flow works
- [ ] Human gates capture input
- [ ] All 606 tests pass
- [ ] CI passes on Linux, macOS, Windows

---

## 6. Risk Assessment & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Hooks don't port 1:1 to plugin API (spawn, capture gaps) | High | High | **Phase 0 prototype** validates bridge approach in Week 1. Accept reduced granularity for spawn guard (use `permission.task` globs). Python guards stay as-is — TS bridge is ~50 lines, not a port. |
| Plugin can't shell out to Python `guards.py` | Medium | High | Plugin uses Bun's built-in `$` shell API. Fallback: embed a thin Node.js wrapper. Phase 0 validates this first. |
| Agent tool grants use deprecated `tools:` format | High | High | Fixed in plan: uses `permission:` with `allow/deny/ask`. Added `mode`, `hidden`, `permission.task` globs. |
| Config precedence confusion | Medium | Medium | Document clearly. `opencode.jsonc` at project root (not in `.opencode/`). Keep harness runtime config in `.claude/context/`. |
| Fork sync conflicts in `.opencode/` or `harness/` | Medium | Medium | Version agents/commands/skills. Rebase workflow. Standard `git merge upstream/main` for Python core. |
| opencode plugin API changes | Low | Medium | Pin `@opencode-ai/plugin` to `^1.17.0`. Test plugin against new versions before upgrading. |
| `CLAUDE_PLUGIN_ROOT` missed in find-and-replace | Medium | High | Scripted search across all `.md` files. Add CI check that no `CLAUDE_PLUGIN_ROOT` references remain. |
| Windows `bun install` behaviour | Low | Low | Test on Windows (Git Bash) before Phase 5. |
| Plugin performance (shell-out overhead) | Low | Low | Shell-out via `$` is ~100ms per guard call. Acceptable for guard invocation frequency. |
| `harness` CLI not on PATH for end users | Medium | High | Plugin can attempt to resolve `bin/harness` relative to plugin directory. Document PATH requirement clearly in README. Shell env hook (if available in opencode) can prepend path. |
| **Tests reference old paths** (`.claude-plugin/plugin.json`, root `agents/`/`skills/`) | **High** | **Medium** | Cross-cutting workstream (8.3) audits all 606 tests in Week 1. Updates applied per-phase. Guard tests unchanged since `hooks/guards.py` stays in Python. |
| npm package name `@shahboura/harness` blocks publish if org changes | Low | Medium | Plan supports rename. Downstream forks use their own org. |

---

## 7. Timeline Summary

| Week | Phases | Key Activities |
|------|--------|----------------|
| Week 1 | **Phase 0** (Plugin Prototype) + **Phase 1** (Foundation) | Plugin skeleton: validate all 7 hooks fire. Config files, AGENTS.md, package.json, sparse-checkout submodule, CLI wrapper, CLAUDE_PLUGIN_ROOT replacement |
| Week 2 | **Phase 2** (Agents) + **Phase 3** (Commands) + **Early Smoke Tests** | 3 agent files (using `permission:` format), 8 command files. Smoke test: `opencode` loads without errors |
| Week 3 | **Phase 4** (Skills) + **Phase 5** (Plugin Complete) | 7 skills copied to `.opencode/skills/`. Plugin E2E: guards block/fire correctly, event capture works |
| Week 4 | **Phase 6** (Config) + **Phase 7** (Docs) + **Phase 8** (Full Testing) | Config docs, README, DISTRIBUTION.md, full E2E: `/dev-workflow` end-to-end, CI/CD, npm pack validation, Windows testing |

**Total: ~4 weeks** (can be parallelized with Phase 0 and Phase 1 running concurrently)

---

## 8. Success Criteria

1. **Distribution**: `git clone <repo> && opencode` → `/init-workspace` works
2. **Parity**: All 8 commands work identically to Claude Code plugin
3. **Guards**: All 7 hook categories enforced via plugin
4. **Tests**: 606 tests pass + new opencode integration tests
5. **Fork Sync**: Documented workflow validated by test fork
6. **Documentation**: README, AGENTS.md, DISTRIBUTION.md complete

---

## 9. Post-Migration Opportunities

- **Publish to npm**: `@ai-sdlc/harness` as opencode plugin package
- **opencode Marketplace**: Submit to ecosystem page
- **Remote Config**: Offer `.well-known/opencode` for org defaults
- **Managed Config**: Support macOS MDM / Linux `/etc/opencode/` for enterprise
- **ACP Support**: Expose harness as ACP server for other clients

---

## Appendix: File Mapping Reference

| Current Path | New Path | Notes |
|--------------|----------|-------|
| `.claude-plugin/plugin.json` | `./opencode.jsonc` (project root) | Schema change + location fix (NOT in .opencode/) |
| `.claude-plugin/marketplace.json` | — | Remove (opencode uses ecosystem) |
| `agents/planner.md` | `.opencode/agents/planner.md` | Change `tools:` to `permission:` format. Add `mode: primary`. |
| `agents/developer.md` | `.opencode/agents/developer.md` | Change `tools:` to `permission:` format. Add `mode: subagent, hidden: true`. |
| `agents/reviewer.md` | `.opencode/agents/reviewer.md` | Change `tools:` to `permission:` format. Add `mode: subagent, hidden: true`. |
| `skills/*/SKILL.md` | `.opencode/skills/*/SKILL.md` | Add frontmatter |
| `skills/*/steps/*.md` | `.opencode/skills/*/steps/*.md` | Copy as-is + replace `CLAUDE_PLUGIN_ROOT` with relative `bin/harness` |
| `hooks/guards.py` | `hooks/guards.py` (unchanged) | **Keep as-is** — bridged by `.opencode/plugins/harness-guards.ts`. Not ported to TS. All guard logic stays in Python. |
| `hooks/hooks.json` | — | Replaced by plugin hooks + agent `permission.task` globs |
| `bin/harness` | `bin/harness` (unchanged) | Already exists, handles `PYTHONPATH` automatically |
| `bin/harness.cmd` | `bin/harness.cmd` (unchanged) | Windows wrapper for cmd.exe |
| `harness/` | `harness/` (unchanged) | Python core - stays at root |
| `pipeline/` | `pipeline/` (unchanged) | Pipeline manifests - stays at root |
| `config/defaults/` | `config/defaults/` (unchanged) | Config defaults - stays at root |
| `tests/` | `tests/` (unchanged) | Tests stay at repo root |
| `tools/` | `tools/` (unchanged) | Meta-tooling stays at root |
| `README.md` | `README.md` | Rewrite install section, add opencode instructions |
| `CHANGELOG.md` | `CHANGELOG.md` | Add migration entry |
| `LICENSE` | `LICENSE` | Unchanged |
| `.gitignore` | `.gitignore` | Add `.opencode/node_modules/` |
| — | `AGENTS.md` | New (root) — replace all `CLAUDE_PLUGIN_ROOT` refs |
| — | `DISTRIBUTION.md` | New — fork sync guide, npm install docs |
| — | `CONTRIBUTING.md` | New (optional) |
| — | `tui.json` | New (project root, alongside `opencode.jsonc`) |
| — | `.opencode/package.json` | New — plugin deps (for `bun install`) |
| — | `.opencode/tsconfig.json` | New — TS config for plugin type resolution |
| — | `package.json` | New — npm package `@shahboura/harness` |
| — | `versions.json` | New — single version + `core_ref` for upstream HEAD |
| — | `scripts/sync-upstream.sh` | New — `git fetch upstream` + merge + versions.json update |